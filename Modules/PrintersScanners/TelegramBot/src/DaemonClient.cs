using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using PrintScan.Shared;

namespace PrintScan.TelegramBot;

/// <summary>
/// Thin HTTP client over the daemon's Unix socket — JSON-typed helpers for
/// the endpoints the bot consumes, plus an SSE reader that yields
/// <see cref="SessionEvent"/>s until the caller's token cancels.
/// </summary>
public sealed class DaemonClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly ILogger<DaemonClient> _logger;

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() }
    };

    public DaemonClient(string socketPath, ILogger<DaemonClient> logger)
    {
        _logger = logger;
        _http = new HttpClient(new SocketsHttpHandler
        {
            // SSE responses stream forever — don't let the handler close
            // the underlying socket on idle.
            ConnectCallback = async (_, ct) =>
            {
                var sock = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                await sock.ConnectAsync(new UnixDomainSocketEndPoint(socketPath), ct);
                return new NetworkStream(sock, ownsSocket: true);
            },
            PooledConnectionLifetime = TimeSpan.FromHours(24),
            PooledConnectionIdleTimeout = Timeout.InfiniteTimeSpan
        }, disposeHandler: true)
        {
            BaseAddress = new Uri("http://localhost"),
            Timeout = Timeout.InfiniteTimeSpan   // the SSE GET needs no timeout
        };
    }

    public enum OpenResult { Opened, Conflict }

    public async Task<(OpenResult Result, SessionRecord? Session, SessionConflict? Conflict)>
        OpenSessionAsync(OpenSessionRequest req, bool takeover, CancellationToken ct)
    {
        var url = "/sessions" + (takeover ? "?takeover=true" : "");
        using var resp = await _http.PostAsJsonAsync(url, req, Json, ct);
        if (resp.StatusCode == System.Net.HttpStatusCode.Conflict)
        {
            var conflict = await resp.Content.ReadFromJsonAsync<SessionConflict>(Json, ct);
            return (OpenResult.Conflict, null, conflict);
        }
        resp.EnsureSuccessStatusCode();
        var s = await resp.Content.ReadFromJsonAsync<SessionRecord>(Json, ct);
        return (OpenResult.Opened, s, null);
    }

    public async Task<SessionRecord?> PatchSessionParamsAsync(
        string sessionId, ScanParams newParams, CancellationToken ct)
    {
        using var resp = await _http.PatchAsJsonAsync(
            $"/sessions/{sessionId}", newParams, Json, ct);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<SessionRecord>(Json, ct);
    }

    public async Task CloseSessionAsync(string sessionId, CancellationToken ct)
    {
        using var resp = await _http.DeleteAsync($"/sessions/{sessionId}", ct);
        if (resp.StatusCode == System.Net.HttpStatusCode.NotFound) return;
        resp.EnsureSuccessStatusCode();
    }

    public async Task RequestScanAsync(string sessionId, CancellationToken ct)
    {
        using var resp = await _http.PostAsync($"/sessions/{sessionId}/scan", content: null, ct);
        resp.EnsureSuccessStatusCode();
    }

    public async Task<Stream> FetchImageAsync(
        string sessionId, int seq, int variant, CancellationToken ct)
    {
        var resp = await _http.GetAsync(
            $"/sessions/{sessionId}/image/{seq}/{variant}",
            HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadAsStreamAsync(ct);
    }

    public async Task<Stream> FetchThumbnailAsync(
        string sessionId, int seq, int variant, CancellationToken ct)
    {
        var resp = await _http.GetAsync(
            $"/sessions/{sessionId}/image/{seq}/{variant}/thumb",
            HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadAsStreamAsync(ct);
    }

    public async Task<DeviceStatus?> GetStatusAsync(CancellationToken ct)
    {
        try
        {
            return await _http.GetFromJsonAsync<DeviceStatus>("/status", Json, ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning("status fetch failed: {Err}", ex.Message);
            return null;
        }
    }

    /// <summary>
    /// Long-lived SSE subscription. Yields events as they arrive. On
    /// connection loss, reconnects with exponential backoff until the
    /// caller's <paramref name="ct"/> cancels.
    /// </summary>
    public async IAsyncEnumerable<SessionEvent> SubscribeAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        var backoff = TimeSpan.FromSeconds(1);
        while (!ct.IsCancellationRequested)
        {
            Stream? body = null;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "/events");
                req.Headers.Accept.ParseAdd("text/event-stream");
                var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
                resp.EnsureSuccessStatusCode();
                body = await resp.Content.ReadAsStreamAsync(ct);
                backoff = TimeSpan.FromSeconds(1);   // reset on successful connect
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                yield break;
            }
            catch (Exception ex)
            {
                _logger.LogWarning("SSE connect failed: {Err}; backoff {Sec}s",
                    ex.Message, backoff.TotalSeconds);
                try { await Task.Delay(backoff, ct); } catch { yield break; }
                backoff = TimeSpan.FromTicks(Math.Min(backoff.Ticks * 2, TimeSpan.FromSeconds(30).Ticks));
                continue;
            }

            using var reader = new StreamReader(body!, Encoding.UTF8);
            var frame = new StringBuilder();
            while (!ct.IsCancellationRequested)
            {
                string? line;
                try { line = await reader.ReadLineAsync(ct); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { yield break; }
                catch (Exception ex)
                {
                    _logger.LogWarning("SSE read error: {Err}", ex.Message);
                    break;  // reconnect
                }
                if (line is null) break;  // EOF → reconnect

                if (line.Length == 0)   // frame terminator
                {
                    if (frame.Length == 0) continue;
                    SessionEvent? ev = null;
                    try { ev = JsonSerializer.Deserialize<SessionEvent>(frame.ToString(), Json); }
                    catch (Exception ex)
                    {
                        _logger.LogWarning("SSE parse error: {Err}", ex.Message);
                    }
                    frame.Clear();
                    if (ev is not null) yield return ev;
                }
                else if (line.StartsWith("data: "))
                {
                    if (frame.Length > 0) frame.Append('\n');
                    frame.Append(line.AsSpan(6));
                }
                // ignore other field types (event:, id:, comments starting with :)
            }
        }
    }

    public void Dispose() => _http.Dispose();
}
