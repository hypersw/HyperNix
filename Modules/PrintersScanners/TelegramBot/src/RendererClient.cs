using System.Net.Sockets;
using Microsoft.Extensions.Logging;

namespace PrintScan.TelegramBot;

/// <summary>
/// Thin HTTP client for the doc → PDF rendering daemon, talking
/// over its Unix socket. The renderer is best-effort: when the
/// daemon is disabled or unreachable, this client throws and the
/// bot's UI surfaces "couldn't render" to the user instead of
/// hanging or silently dropping the file.
/// </summary>
public sealed class RendererClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly ILogger<RendererClient> _logger;
    private readonly string _socketPath;

    public bool Enabled { get; }

    public RendererClient(string? socketPath, ILogger<RendererClient> logger)
    {
        _logger = logger;
        _socketPath = socketPath ?? "";
        Enabled = !string.IsNullOrEmpty(socketPath);
        _http = new HttpClient(new SocketsHttpHandler
        {
            ConnectCallback = async (_, ct) =>
            {
                var sock = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                await sock.ConnectAsync(new UnixDomainSocketEndPoint(_socketPath), ct);
                return new NetworkStream(sock, ownsSocket: true);
            },
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        }, disposeHandler: true)
        {
            BaseAddress = new Uri("http://localhost"),
            // Renderer's hard-cap on a single soffice run is ~2 minutes
            // (see Renderer/Program.cs). Cold-start of soffice on Pi 4
            // is ~5–10 s, so a 3-minute client-side timeout
            // comfortably covers anything the renderer can produce
            // without opening us up to indefinite hangs on a bug.
            Timeout = TimeSpan.FromMinutes(3),
        };
    }

    /// <summary>
    /// Convert a document to PDF via the renderer daemon. Returns the
    /// PDF bytes on success. Throws on any non-2xx response — the
    /// bot's caller catches and surfaces a "render failed" message.
    /// </summary>
    public async Task<byte[]> RenderAsync(
        byte[] sourceBytes, string fileName, string contentType, CancellationToken ct)
    {
        if (!Enabled)
            throw new InvalidOperationException(
                "Renderer disabled (PRINTSCAN_RENDERER_SOCKET not set)");

        using var content = new System.Net.Http.MultipartFormDataContent();
        var fileContent = new System.Net.Http.ByteArrayContent(sourceBytes);
        fileContent.Headers.ContentType =
            new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
        content.Add(fileContent, "file", fileName);

        var sw = System.Diagnostics.Stopwatch.StartNew();
        using var resp = await _http.PostAsync("/render", content, ct);
        sw.Stop();
        if (!resp.IsSuccessStatusCode)
        {
            var detail = await resp.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException(
                $"renderer returned {(int)resp.StatusCode}: {detail.Trim()}");
        }
        var bytes = await resp.Content.ReadAsByteArrayAsync(ct);
        _logger.LogInformation(
            "rendered {File} ({InBytes}B) → PDF ({OutBytes}B) in {Elapsed:F1}s",
            fileName, sourceBytes.Length, bytes.Length, sw.Elapsed.TotalSeconds);
        return bytes;
    }

    public void Dispose() => _http.Dispose();
}
