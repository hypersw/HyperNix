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
            // Sized for the longest endpoint: realesrgan's
            // /image-upscale has a 5-minute internal hard cap (CPU
            // fallback path on a Pi can chew through that on a big
            // graphics-class image). 6 minutes leaves a minute of
            // slack for the renderer to send back its 504 timeout
            // response cleanly, which the bot then maps to
            // "neural upscaler failed → fall back to Lanczos3".
            // /render and /pdf-preview are typically <30s; they
            // sit comfortably inside this ceiling.
            Timeout = TimeSpan.FromMinutes(6),
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
    /// Rasterise the first <paramref name="maxPages"/> pages of a
    /// PDF into a single grayscale WebP, stacked vertically. Used
    /// by the bot's preview path — a multi-page document gets its
    /// first few pages composited into one image and shipped as a
    /// Telegram Document so the user sees what'll print without
    /// the platform recompressing the bytes. Returns null on any
    /// failure so the caller can fall back to the bare-PDF send.
    /// </summary>
    public async Task<byte[]?> GetPdfPreviewAsync(
        byte[] pdfBytes, string fileName, int maxPages, CancellationToken ct)
    {
        if (!Enabled) return null;
        try
        {
            using var content = new System.Net.Http.MultipartFormDataContent();
            var fileContent = new System.Net.Http.ByteArrayContent(pdfBytes);
            fileContent.Headers.ContentType =
                new System.Net.Http.Headers.MediaTypeHeaderValue("application/pdf");
            content.Add(fileContent, "file", fileName);
            content.Add(new System.Net.Http.StringContent(maxPages.ToString()), "maxPages");

            using var resp = await _http.PostAsync("/pdf-preview", content, ct);
            if (!resp.IsSuccessStatusCode) return null;
            return await resp.Content.ReadAsByteArrayAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogDebug("pdf-preview failed for {File}: {Err}", fileName, ex.Message);
            return null;
        }
    }

    /// <summary>
    /// Run a graphics-class image through the renderer's neural
    /// upscaler (Real-ESRGAN with the realesr-animevideov3 model).
    /// Returns null on any failure — caller catches the null and
    /// falls back to the bot-side Lanczos3 path so the print still
    /// goes through. The renderer itself already does GPU→CPU
    /// fallback for Vulkan-less hosts; this null is reserved for
    /// "even CPU mode failed" / "renderer unreachable" / non-2xx.
    ///
    /// Stamps the upscaled PNG with `pHYs = sourceDpi × scale` before
    /// returning. realesrgan-ncnn-vulkan strips resolution metadata
    /// from its output, which used to cascade through PrintPreprocess
    /// as "source DPI = 96 default" and produce a 6×-too-large image
    /// declared at 6×-too-low DPI; see Print Flow Update 2026-05-17
    /// in PLAN.md for the full story. Re-stamping at the API boundary
    /// keeps downstream consumers honest without each having to know
    /// the upscaler's quirks.
    /// </summary>
    public async Task<byte[]?> UpscaleAsync(
        byte[] sourceBytes, string fileName, int scale, double sourceDpi,
        CancellationToken ct)
    {
        if (!Enabled)
        {
            _logger.LogWarning(
                "neural upscale skipped — renderer disabled (no socket); " +
                "graphics-class image {File} will fall back to Lanczos3",
                fileName);
            return null;
        }
        try
        {
            using var content = new System.Net.Http.MultipartFormDataContent();
            var fileContent = new System.Net.Http.ByteArrayContent(sourceBytes);
            fileContent.Headers.ContentType =
                new System.Net.Http.Headers.MediaTypeHeaderValue("image/png");
            content.Add(fileContent, "file", fileName);
            content.Add(new System.Net.Http.StringContent(scale.ToString()), "scale");
            content.Add(new System.Net.Http.StringContent("realesr-animevideov3"), "model");
            content.Add(new System.Net.Http.StringContent("auto"), "gpu");

            var sw = System.Diagnostics.Stopwatch.StartNew();
            using var resp = await _http.PostAsync("/image-upscale", content, ct);
            sw.Stop();
            if (!resp.IsSuccessStatusCode)
            {
                var detail = (await resp.Content.ReadAsStringAsync(ct)).Trim();
                if (detail.Length > 600) detail = detail[..600] + "…";
                // Error-level so the operator's journalctl filter
                // catches it — this is the "report to monitoring"
                // hook for the upscaler-failure case.
                _logger.LogError(
                    "neural upscale FAILED for {File}: HTTP {Status} — {Detail}; " +
                    "falling back to Lanczos3",
                    fileName, (int)resp.StatusCode, detail);
                return null;
            }
            var rawBytes = await resp.Content.ReadAsByteArrayAsync(ct);

            // pHYs enforcement: realesrgan-ncnn strips resolution
            // metadata. We know what it SHOULD be (sourceDpi × scale
            // — physical print size is preserved by the upscale,
            // pixels-per-inch grows by the upscale factor). Re-encode
            // the PNG with the correct pHYs stamp before returning.
            var stampedBytes = await StampPngDpiAsync(rawBytes, sourceDpi * scale, ct);

            _logger.LogInformation(
                "neural upscale OK for {File}: {InBytes}B → {OutBytes}B " +
                "(stamped @ {Dpi:F0} dpi) in {Elapsed:F1}s",
                fileName, sourceBytes.Length, stampedBytes.Length,
                sourceDpi * scale, sw.Elapsed.TotalSeconds);
            return stampedBytes;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex,
                "neural upscale CRASHED for {File}; falling back to Lanczos3",
                fileName);
            return null;
        }
    }

    /// <summary>
    /// Decode a PNG, set its pHYs chunk to <paramref name="dpi"/> on
    /// both axes, re-encode. Used to fix realesrgan-ncnn's habit of
    /// dropping the resolution chunk on its output. Falls back to
    /// the input bytes verbatim on any decode/encode error — better
    /// to have a DPI-less PNG than no output at all (downstream
    /// PrintPreprocess will still complete with a 96-dpi fallback).
    /// </summary>
    private async Task<byte[]> StampPngDpiAsync(
        byte[] pngBytes, double dpi, CancellationToken ct)
    {
        try
        {
            using var img = await SixLabors.ImageSharp.Image.LoadAsync(
                new MemoryStream(pngBytes, writable: false), ct);
            img.Metadata.HorizontalResolution = dpi;
            img.Metadata.VerticalResolution   = dpi;
            // ImageSharp's PNG encoder writes ResolutionUnits separately
            // from the Image's Metadata.ResolutionUnits property. Set
            // PixelsPerInch explicitly so the pHYs unit byte (1 = m,
            // 0 = unspecified) is correct — ImageSharp converts dpi
            // to pixels-per-meter under the hood when writing.
            img.Metadata.ResolutionUnits =
                SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerInch;
            using var ms = new MemoryStream();
            // SaveAsPngAsync is only an extension on Image<TPixel>; on
            // the non-generic Image returned by LoadAsync we go through
            // SaveAsync with an explicit PngEncoder. Same on-disk output.
            await img.SaveAsync(
                ms,
                new SixLabors.ImageSharp.Formats.Png.PngEncoder(),
                ct);
            return ms.ToArray();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "could not stamp pHYs on upscaler output ({Bytes}B); " +
                "passing through unmodified",
                pngBytes.Length);
            return pngBytes;
        }
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
