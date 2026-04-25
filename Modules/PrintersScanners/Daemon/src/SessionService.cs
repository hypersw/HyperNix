using Microsoft.IO;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Owns the single active session and all scan-lifecycle logic. Persists
/// changes via <see cref="SessionStore"/>, fans out progress via
/// <see cref="EventBroker"/>. Image bytes stay resident in memory (a
/// <see cref="RecyclableMemoryStream"/> per captured image) until the owning
/// session closes — bots fetch them via <c>GET /sessions/{id}/image/{seq}</c>.
/// </summary>
public sealed class SessionService : IAsyncDisposable
{
    private static readonly TimeSpan SessionWindow = TimeSpan.FromMinutes(10);

    private readonly SessionStore _store;
    private readonly EventBroker _broker;
    private readonly ScanPipeline _pipeline;
    private readonly ShutdownGate _gate;
    private readonly ILogger<SessionService> _logger;

    // Per-session captured TIFF blobs keyed by (sessionId, seq). One
    // blob per scan; the daemon never re-encodes or thumbnails — that's
    // the client's job. Entries are dropped on first successful fetch
    // (so memory doesn't pile up across many scans within a session)
    // and any survivors are disposed when the session terminates.
    private readonly Dictionary<(string SessionId, int Seq), RecyclableMemoryStream> _scans = [];

    // Queued-scan counter. User taps Scan while a scan is in flight →
    // this goes up → the running scan loop drains it as each scan
    // completes. Capped at 1 — "queue one more after the current one"
    // covers the serial-scan workflow; there's no realistic user need
    // to queue further ahead than that.
    private int _scanQueue;
    private const int ScanQueueMax = 1;

    // lock covers: the image dictionary, in-flight flag transitions, takeover
    // handshake, session replacement.
    private readonly Lock _lock = new();

    // a completion that fires whenever the current in-flight scan ends —
    // used by takeover to wait for an active scan to finish before handing
    // the session over.
    private TaskCompletionSource<object?>? _scanIdle = null;

    // background expiry timer
    private readonly CancellationTokenSource _expiryCts = new();
    private Task? _expiryTask;

    public SessionService(
        SessionStore store, EventBroker broker, ScanPipeline pipeline,
        ShutdownGate gate, ILogger<SessionService> logger)
    {
        _store = store;
        _broker = broker;
        _pipeline = pipeline;
        _gate = gate;
        _logger = logger;

        _expiryTask = RunExpiryLoop(_expiryCts.Token);
    }

    public SessionRecord? Current => _store.Current;

    // ── Open / takeover ─────────────────────────────────────────────────────

    public enum OpenOutcome { Opened, Conflict }

    public (OpenOutcome Outcome, SessionRecord? Session, SessionRecord? Existing)
        TryOpen(OpenSessionRequest req, bool takeover)
    {
        SessionRecord? existing;
        lock (_lock) { existing = _store.Current; }

        if (existing is not null && !takeover)
            return (OpenOutcome.Conflict, null, existing);

        if (existing is not null)
        {
            // takeover — wait for any in-flight scan, then close previous and emit event
            WaitForScanIdle().GetAwaiter().GetResult();
            TerminateInternal(existing, SessionTerminationReason.Takeover, req.OwnerDisplayName);
        }

        var session = new SessionRecord(
            Id: Guid.NewGuid().ToString("N")[..12],
            OwnerBot: req.OwnerBot,
            OwnerChatId: req.OwnerChatId,
            OwnerStatusMessageId: req.OwnerStatusMessageId,
            OwnerDisplayName: req.OwnerDisplayName,
            Params: req.Params,
            Opened: DateTimeOffset.UtcNow,
            ExpiresAt: DateTimeOffset.UtcNow + SessionWindow);

        _store.Set(session);
        _broker.Publish(new SessionEvent(
            SessionEventType.SessionOpened,
            Session: session, SessionId: session.Id));
        _logger.LogInformation("session {Id} opened by {Owner}", session.Id, session.OwnerDisplayName);
        return (OpenOutcome.Opened, session, null);
    }

    /// <summary>
    /// Update the session's scan parameters mid-flight. In-flight scans
    /// keep the params they started with; next scan uses the new values.
    /// Emits a <c>SessionOpened</c> event with the updated record so
    /// subscribers re-render.
    /// </summary>
    public SessionRecord UpdateParams(string sessionId, ScanParams newParams)
    {
        lock (_lock)
        {
            var current = _store.Current
                ?? throw new InvalidOperationException("No active session");
            if (current.Id != sessionId)
                throw new InvalidOperationException("Session ID mismatch");
            var updated = _store.Mutate(s => s with { Params = newParams });
            _broker.Publish(new SessionEvent(
                SessionEventType.SessionOpened,
                SessionId: updated.Id, Session: updated));
            _logger.LogInformation("session {Id} params updated: dpi={Dpi}",
                updated.Id, newParams.Dpi);
            return updated;
        }
    }

    /// <summary>
    /// Replace the session's client metadata bag wholesale. The daemon
    /// never inspects the contents — this is opaque storage so clients
    /// (the Telegram bot today) can persist their own per-session state
    /// without us having to add a new typed field for every concern.
    /// Emits a <c>SessionOpened</c> event so the writing client (or
    /// any other subscriber) re-renders.
    /// </summary>
    public SessionRecord UpdateMetadata(string sessionId, Dictionary<string, string> metadata)
    {
        lock (_lock)
        {
            var current = _store.Current
                ?? throw new InvalidOperationException("No active session");
            if (current.Id != sessionId)
                throw new InvalidOperationException("Session ID mismatch");
            var updated = _store.Mutate(s => s with { Metadata = metadata });
            _broker.Publish(new SessionEvent(
                SessionEventType.SessionOpened,
                SessionId: updated.Id, Session: updated));
            _logger.LogInformation("session {Id} metadata updated: {Keys}",
                updated.Id, string.Join(",", metadata.Keys));
            return updated;
        }
    }

    public bool Close(string sessionId, SessionTerminationReason reason)
    {
        SessionRecord? current;
        lock (_lock) { current = _store.Current; }
        if (current is null || current.Id != sessionId) return false;
        TerminateInternal(current, reason, null);
        return true;
    }

    private void TerminateInternal(SessionRecord session, SessionTerminationReason reason, string? newOwner)
    {
        lock (_lock)
        {
            // dispose any TIFFs not yet fetched by the bot
            var keys = _scans.Keys.Where(k => k.SessionId == session.Id).ToList();
            foreach (var k in keys)
            {
                _scans[k].Dispose();
                _scans.Remove(k);
            }
            _store.Set(null);
        }
        _broker.Publish(new SessionEvent(
            SessionEventType.SessionTerminated,
            SessionId: session.Id, Session: session,
            Reason: reason, NewOwner: newOwner));
        _logger.LogInformation("session {Id} terminated ({Reason})", session.Id, reason);
    }

    // ── Extend / expiry ─────────────────────────────────────────────────────

    private SessionRecord ExtendWindow(SessionRecord s)
    {
        var extended = s with { ExpiresAt = DateTimeOffset.UtcNow + SessionWindow };
        _store.Set(extended);
        _broker.Publish(new SessionEvent(
            SessionEventType.SessionExtended,
            SessionId: extended.Id, Session: extended, ExpiresAt: extended.ExpiresAt));
        return extended;
    }

    private async Task RunExpiryLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(30), ct); }
            catch (OperationCanceledException) { return; }

            SessionRecord? current;
            lock (_lock) { current = _store.Current; }
            if (current is not null && DateTimeOffset.UtcNow >= current.ExpiresAt)
            {
                _logger.LogInformation("session {Id} expired", current.Id);
                TerminateInternal(current, SessionTerminationReason.Timeout, null);
            }
        }
    }

    // ── Scan ────────────────────────────────────────────────────────────────

    public Task<int> RequestScanAsync(string sessionId, CancellationToken ct)
    {
        // Synchronous entry: either start the scan loop (fire-and-forget)
        // or enqueue behind the currently-running one. Returns quickly
        // in both cases so the HTTP POST /scan response is snappy even
        // when the actual scan takes seconds.
        lock (_lock)
        {
            var current = _store.Current
                ?? throw new InvalidOperationException("No active session");
            if (current.Id != sessionId)
                throw new InvalidOperationException("Session ID mismatch (taken over?)");

            if (current.InFlightScan)
            {
                // Already scanning — queue one up (but only one ever:
                // ScanQueueMax=1). If there's already one queued, treat
                // the tap as a silent no-op. No error thrown because the
                // UI already shows "+1 queued" and a second tap just
                // means "yes I know, still one queued" — any error
                // popup would confuse more than inform.
                if (_scanQueue >= ScanQueueMax)
                {
                    _logger.LogDebug(
                        "scan queue already at max ({Max}) — ignoring duplicate tap",
                        ScanQueueMax);
                    return Task.FromResult(current.ScanCount + 1 + _scanQueue);
                }
                _scanQueue++;
                _broker.Publish(new SessionEvent(
                    SessionEventType.SessionScanQueued,
                    SessionId: sessionId, QueuedCount: _scanQueue));
                _logger.LogInformation(
                    "scan queued for {Id}: queue depth now {N}", sessionId, _scanQueue);
                return Task.FromResult(current.ScanCount + 1 + _scanQueue);
            }

            // Nothing in flight — start the scan loop. Tied to the
            // service-level expiry CTS so it terminates on shutdown;
            // not to the HTTP request ct, which would end the scan as
            // soon as this method returns.
            _store.Mutate(s => s with { InFlightScan = true });
            _scanIdle = new TaskCompletionSource<object?>();
            _ = Task.Run(() => RunScanLoopAsync(sessionId, _expiryCts.Token));
            return Task.FromResult(current.ScanCount + 1);
        }
    }

    /// <summary>
    /// Runs scans back-to-back from the queue until it drains. Each
    /// iteration processes one full scan (scanimage → decode → N encodes
    /// → publish N image-ready events). Failures drop the queue —
    /// operator re-taps Scan to resume.
    /// </summary>
    private async Task RunScanLoopAsync(string sessionId, CancellationToken ct)
    {
        try
        {
            while (true)
            {
                int queueDepth;
                int seq;
                SessionRecord session;
                lock (_lock)
                {
                    var current = _store.Current;
                    if (current is null || current.Id != sessionId)
                    {
                        // Session gone (closed / taken over). Bail —
                        // queue is implicitly dropped.
                        return;
                    }
                    session = _store.Mutate(s => s with { InFlightScan = true });
                    seq = session.ScanCount + 1;
                    queueDepth = _scanQueue;
                }

                using var gate = _gate.Begin($"scan {sessionId}#{seq}");
                _broker.Publish(new SessionEvent(
                    SessionEventType.SessionScanning,
                    SessionId: sessionId, Seq: seq, QueuedCount: queueDepth));

                try
                {
                    var progress = new Progress<int>(pct =>
                        _broker.Publish(new SessionEvent(
                            SessionEventType.SessionScanProgress,
                            SessionId: sessionId, Seq: seq, PercentDone: pct)));
                    var tiff = await _pipeline.ScanAsync(session.Params, progress, ct);
                    long bytes;
                    lock (_lock)
                    {
                        _scans[(sessionId, seq)] = tiff;
                        bytes = tiff.Length;
                        var extended = _store.Mutate(s => s with
                        {
                            InFlightScan = false,
                            ScanCount = seq
                        });
                        ExtendWindow(extended);
                    }
                    _broker.Publish(new SessionEvent(
                        SessionEventType.SessionImageReady,
                        SessionId: sessionId, Seq: seq, BytesLength: bytes));
                }
                catch (Exception ex)
                {
                    lock (_lock)
                    {
                        if (_store.Current is not null && _store.Current.Id == sessionId)
                            _store.Mutate(s => s with { InFlightScan = false });
                        // Drop queue on failure. User can re-tap to resume.
                        _scanQueue = 0;
                    }
                    _broker.Publish(new SessionEvent(
                        SessionEventType.SessionScanFailed,
                        SessionId: sessionId, Seq: seq, Error: ex.Message));
                    _logger.LogError(ex, "scan failed for session {Id}#{Seq}", sessionId, seq);
                    return;  // exit loop on failure
                }

                // Drain one queue slot or exit.
                lock (_lock)
                {
                    if (_scanQueue > 0)
                    {
                        _scanQueue--;
                        continue;
                    }
                    return;  // queue empty, scan loop done
                }
            }
        }
        finally
        {
            lock (_lock)
            {
                if (_store.Current is not null && _store.Current.Id == sessionId)
                    _store.Mutate(s => s with { InFlightScan = false });
                _scanIdle?.TrySetResult(null);
                _scanIdle = null;
            }
        }
    }

    private Task WaitForScanIdle()
    {
        lock (_lock)
        {
            return _scanIdle?.Task ?? Task.CompletedTask;
        }
    }

    // ── Image fetch ─────────────────────────────────────────────────────────

    /// <summary>
    /// Returns the captured TIFF for this scan as a read-only stream
    /// view, rewound to the start. The daemon retains ownership — it's
    /// the caller's job to send <see cref="RemoveScan"/> once they've
    /// finished consuming it (typically: bot fetches, uploads, then
    /// deletes). If the caller never deletes, the stream is bounded
    /// instead by session lifetime: <see cref="TerminateInternal"/>
    /// disposes any survivors at session end (idle timeout / explicit
    /// close / takeover).
    /// </summary>
    public RecyclableMemoryStream? GetScan(string sessionId, int seq)
    {
        lock (_lock)
        {
            if (!_scans.TryGetValue((sessionId, seq), out var stream))
                return null;
            stream.Position = 0;
            return stream;
        }
    }

    /// <summary>
    /// Drop the captured TIFF for this scan and dispose its stream.
    /// Returns true if the entry existed, false if it had already been
    /// removed (or was never created). Idempotent — calling twice is
    /// safe.
    /// </summary>
    public bool RemoveScan(string sessionId, int seq)
    {
        lock (_lock)
        {
            if (!_scans.Remove((sessionId, seq), out var stream))
                return false;
            stream.Dispose();
            return true;
        }
    }

    // ── Shutdown ────────────────────────────────────────────────────────────

    public async ValueTask DisposeAsync()
    {
        _logger.LogInformation("SessionService.DisposeAsync: entry");
        _expiryCts.Cancel();
        _logger.LogInformation("SessionService.DisposeAsync: expiry-cts cancelled");
        if (_expiryTask is not null)
        {
            try { await _expiryTask; }
            catch (Exception ex) { _logger.LogDebug(ex, "expiry task exit"); }
        }
        _logger.LogInformation("SessionService.DisposeAsync: expiry task joined");
        lock (_lock)
        {
            foreach (var s in _scans.Values) s.Dispose();
            _scans.Clear();
        }
        _logger.LogInformation("SessionService.DisposeAsync: done");
    }
}

