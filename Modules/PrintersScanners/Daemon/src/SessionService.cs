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

    // per-session scan storage, keyed by sessionId + seq
    private readonly Dictionary<(string SessionId, int Seq), CapturedImage> _images = [];

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
            _logger.LogInformation("session {Id} params updated: dpi={Dpi} fmt={Fmt}",
                updated.Id, newParams.Dpi, newParams.Format);
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
            // drop any held images
            var keys = _images.Keys.Where(k => k.SessionId == session.Id).ToList();
            foreach (var k in keys)
            {
                _images[k].Dispose();
                _images.Remove(k);
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

    public async Task<int> RequestScanAsync(string sessionId, CancellationToken ct)
    {
        SessionRecord session;
        int seq;
        lock (_lock)
        {
            var current = _store.Current
                ?? throw new InvalidOperationException("No active session");
            if (current.Id != sessionId)
                throw new InvalidOperationException("Session ID mismatch (taken over?)");
            if (current.InFlightScan)
                throw new InvalidOperationException("Scan already in flight");

            session = _store.Mutate(s => s with { InFlightScan = true });
            seq = session.ScanCount + 1;
            _scanIdle = new TaskCompletionSource<object?>();
        }

        using var gate = _gate.Begin($"scan {sessionId}#{seq}");
        _broker.Publish(new SessionEvent(
            SessionEventType.SessionScanning, SessionId: sessionId, Seq: seq));

        try
        {
            // Progress bridge: IProgress<int> from the pipeline → SSE event
            // to the bot(s). Progress<T> invokes its callback on the
            // original SynchronizationContext (or thread-pool if none),
            // so publishing to the broker is safe from background threads.
            var progress = new Progress<int>(pct =>
                _broker.Publish(new SessionEvent(
                    SessionEventType.SessionScanProgress,
                    SessionId: sessionId, Seq: seq, PercentDone: pct)));
            var result = await _pipeline.ScanAsync(session.Params, progress, ct);
            var captured = new CapturedImage(result.Data, result.ContentType,
                $"scan-{sessionId}-{seq}.{result.FileExtension}");
            lock (_lock)
            {
                _images[(sessionId, seq)] = captured;
                var extended = _store.Mutate(s => s with
                {
                    InFlightScan = false,
                    ScanCount = seq
                });
                // also bump the sliding window
                ExtendWindow(extended);
            }
            _broker.Publish(new SessionEvent(
                SessionEventType.SessionImageReady,
                SessionId: sessionId, Seq: seq,
                ContentType: result.ContentType, FileName: captured.FileName,
                BytesLength: result.Data.Length));
            return seq;
        }
        catch (Exception ex)
        {
            lock (_lock)
            {
                if (_store.Current is not null && _store.Current.Id == sessionId)
                    _store.Mutate(s => s with { InFlightScan = false });
            }
            _broker.Publish(new SessionEvent(
                SessionEventType.SessionScanFailed,
                SessionId: sessionId, Seq: seq, Error: ex.Message));
            _logger.LogError(ex, "scan failed for session {Id}#{Seq}", sessionId, seq);
            throw;
        }
        finally
        {
            lock (_lock)
            {
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

    public CapturedImage? GetImage(string sessionId, int seq)
    {
        lock (_lock)
        {
            _images.TryGetValue((sessionId, seq), out var img);
            return img;
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
            foreach (var img in _images.Values) img.Dispose();
            _images.Clear();
        }
        _logger.LogInformation("SessionService.DisposeAsync: done");
    }
}

/// <summary>
/// One captured image. Owns a RecyclableMemoryStream; disposed when the
/// session that produced it terminates.
/// </summary>
public sealed class CapturedImage : IDisposable
{
    public RecyclableMemoryStream Data { get; }
    public string ContentType { get; }
    public string FileName { get; }

    public CapturedImage(RecyclableMemoryStream data, string contentType, string fileName)
    {
        Data = data; ContentType = contentType; FileName = fileName;
    }

    public void Dispose() => Data.Dispose();
}
