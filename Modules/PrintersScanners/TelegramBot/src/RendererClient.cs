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
            // The renderer returns ProblemDetails (RFC 7807) JSON for
            // tool failures, with title=friendly summary and
            // detail=raw stderr. Parse it back so the bot's UI can
            // show the friendly summary inline and tuck the raw
            // text into a <pre> block. Falls back to plaintext for
            // any non-JSON error body.
            var bodyStr = await resp.Content.ReadAsStringAsync(ct);
            string? title = null, detail = bodyStr;
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(bodyStr);
                if (doc.RootElement.TryGetProperty("title", out var t))
                    title = t.GetString();
                if (doc.RootElement.TryGetProperty("detail", out var d))
                    detail = d.GetString() ?? bodyStr;
            }
            catch (System.Text.Json.JsonException)
            {
                // Plain text body — keep both fields equal so the
                // caller still has *something* to show.
            }
            throw new RenderFailedRemotely(
                (int)resp.StatusCode,
                title ?? $"renderer returned HTTP {(int)resp.StatusCode}",
                detail ?? "");
        }
        var bytes = await resp.Content.ReadAsByteArrayAsync(ct);
        _logger.LogInformation(
            "rendered {File} ({InBytes}B) → PDF ({OutBytes}B) in {Elapsed:F1}s",
            fileName, sourceBytes.Length, bytes.Length, sw.Elapsed.TotalSeconds);
        return bytes;
    }

    /// <summary>
    /// Convert a device-specific image container (HEIC, AVIF) into
    /// a vanilla PNG that ImageSharp can decode. Throws on failure
    /// — the bot caller surfaces a friendly message.
    /// </summary>
    public async Task<byte[]> ConvertImageAsync(
        byte[] sourceBytes, string fileName, string contentType,
        CancellationToken ct)
    {
        if (!Enabled)
            throw new InvalidOperationException(
                "Renderer disabled (PRINTSCAN_RENDERER_SOCKET not set)");

        using var content = new System.Net.Http.MultipartFormDataContent();
        var fileContent = new System.Net.Http.ByteArrayContent(sourceBytes);
        fileContent.Headers.ContentType =
            new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
        content.Add(fileContent, "file", fileName);

        using var resp = await _http.PostAsync("/image-convert", content, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var bodyStr = await resp.Content.ReadAsStringAsync(ct);
            string? title = null, detail = bodyStr;
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(bodyStr);
                if (doc.RootElement.TryGetProperty("title", out var t))
                    title = t.GetString();
                if (doc.RootElement.TryGetProperty("detail", out var d))
                    detail = d.GetString() ?? bodyStr;
            }
            catch (System.Text.Json.JsonException) { }
            throw new RenderFailedRemotely(
                (int)resp.StatusCode,
                title ?? $"image converter returned HTTP {(int)resp.StatusCode}",
                detail ?? "");
        }
        return await resp.Content.ReadAsByteArrayAsync(ct);
    }

    /// <summary>
    /// Ask the renderer how many pages are in this PDF. Best-effort:
    /// returns null if the daemon's disabled, the call errors, or
    /// pdfinfo couldn't read the file. Used to decide whether to
    /// show the bot's per-page checkbox UI vs the digit-keyboard
    /// custom-range picker.
    /// </summary>
    public async Task<int?> GetPdfPageCountAsync(
        byte[] pdfBytes, string fileName, CancellationToken ct)
    {
        if (!Enabled) return null;
        try
        {
            using var content = new System.Net.Http.MultipartFormDataContent();
            var fileContent = new System.Net.Http.ByteArrayContent(pdfBytes);
            fileContent.Headers.ContentType =
                new System.Net.Http.Headers.MediaTypeHeaderValue("application/pdf");
            content.Add(fileContent, "file", fileName);
            using var resp = await _http.PostAsync("/pdf-info", content, ct);
            if (!resp.IsSuccessStatusCode) return null;
            var doc = await System.Text.Json.JsonDocument.ParseAsync(
                await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            if (doc.RootElement.TryGetProperty("pageCount", out var pc) &&
                pc.TryGetInt32(out var n))
                return n;
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogDebug("pdf-info failed for {File}: {Err}", fileName, ex.Message);
            return null;
        }
    }

    public void Dispose() => _http.Dispose();
}

/// <summary>
/// Thrown by <see cref="RendererClient.RenderAsync"/> when the
/// renderer returned a structured failure. The caller surfaces
/// <see cref="Friendly"/> as a one-liner banner to the user and
/// (optionally) tucks <see cref="RawDetail"/> into an expander or
/// monospace block for diagnosis.
/// </summary>
public sealed class RenderFailedRemotely : Exception
{
    public int HttpStatus { get; }
    public string Friendly { get; }
    public string RawDetail { get; }
    public RenderFailedRemotely(int httpStatus, string friendly, string rawDetail)
        : base(friendly)
    {
        HttpStatus = httpStatus;
        Friendly = friendly;
        RawDetail = rawDetail;
    }
}
