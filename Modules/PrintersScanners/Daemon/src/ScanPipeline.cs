using System.Diagnostics;
using Microsoft.IO;
using PrintScan.Shared;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Formats.Tiff;
using SixLabors.ImageSharp.Formats.Tiff.Constants;
using SixLabors.ImageSharp.Formats.Webp;
using SixLabors.ImageSharp.PixelFormats;

namespace PrintScan.Daemon;

/// <summary>
/// Scans a page by driving <c>scanimage</c> at USB-limited speed (no
/// on-the-fly compression at scanimage level) and then re-encoding the
/// result in-process to the user's chosen container with sensible
/// quality settings.
///
/// Why the two-step pipeline: scanimage's JPEG/PNG output path does
/// libjpeg/libpng encoding synchronously per row. On a Pi 4 A72 the
/// libpng zlib level-6 encoder runs at ~5-15 MB/s, which is slower
/// than the scanner's ~3-5 MB/s feed at 200 dpi color but not by
/// much — and enough to stall the USB read, back-pressure the SANE
/// backend, and cause the scanner to pause the carriage mid-page
/// (it literally retracts and re-scans to catch up).
///
/// Uncompressed TIFF from scanimage is effectively "header + raw
/// pixel rows" — zero CPU at scanimage, USB-limited. We then do the
/// "real" encode here, offline from the scanner, where nothing
/// back-pressures. Even on a Pi, ImageSharp's JPEG encode on an A72
/// is ~20-40 MB/s and PNG/TIFF-Deflate are in the same ballpark —
/// well above the scanner's peak feed.
/// </summary>
public sealed class ScanPipeline
{
    private static readonly RecyclableMemoryStreamManager Pool = new(
        new RecyclableMemoryStreamManager.Options
        {
            BlockSize = 128 * 1024,            // 128 KB blocks
            LargeBufferMultiple = 1024 * 1024, // 1 MB large-buffer step
            MaximumBufferSize = 16 * 1024 * 1024, // 16 MB cap per block
            GenerateCallStacks = false,
            AggressiveBufferReturn = true
        });

    // Baked-in JPEG quality. Q=85 with 4:4:4 chroma is "document scan
    // sensible" — noticeably better than libjpeg's Q=75 default which
    // produces visible ringing around text and chroma smearing. Users
    // who need reprint-grade output pick PNG or TIFF instead; there's
    // deliberately no knob here.
    private const int JpegQuality = 85;

    private readonly ILogger<ScanPipeline> _logger;

    public ScanPipeline(ILogger<ScanPipeline> logger) { _logger = logger; }

    public record Result(RecyclableMemoryStream Data, string ContentType, string FileExtension);

    /// <summary>
    /// Scan synchronously, decode, re-encode, return the encoded stream.
    /// Caller owns the stream and must dispose it. Throws on non-zero
    /// exit or spawn failure. Optional <paramref name="progress"/> is
    /// reported 0..100 while scanimage is streaming bytes (estimated
    /// from expected A4-page size — rough but close enough for a UI
    /// progress bar), and then 100 when encoding completes.
    /// </summary>
    public async Task<Result> ScanAsync(
        ScanParams p, IProgress<int>? progress, CancellationToken ct)
    {
        // Field-test instrumentation: the whole pipeline is whole-buffer
        // (scanimage → TIFF blob → Image<Rgb24> decode → encoded blob),
        // so we log elapsed + memory at each phase transition. That lets
        // us judge whether we're hitting buffer limits, GC pressure, or
        // decode-bound CPU on the Pi without having to re-instrument.
        var total = Stopwatch.StartNew();
        var proc0 = Process.GetCurrentProcess();
        long MemRss() { proc0.Refresh(); return proc0.WorkingSet64; }
        long MemManaged() => GC.GetTotalMemory(false);
        string Fmt(long bytes) => $"{bytes / 1024.0 / 1024.0:F1} MB";
        _logger.LogInformation(
            "scan start: dpi={Dpi} format={Format} rss={Rss} heap={Heap}",
            p.Dpi, p.Format, Fmt(MemRss()), Fmt(MemManaged()));

        // ── Step 1: scanimage → uncompressed TIFF ──────────────────────────
        // No CPU work at scanimage beyond reading from USB and writing
        // a TIFF header + rows; USB-limited.
        var args = $"--resolution {p.Dpi} --format tiff";
        _logger.LogInformation("scanimage {Args}", args);
        var scanT = Stopwatch.StartNew();

        var psi = new ProcessStartInfo(ToolPaths.ScanImage, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        using var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start scanimage");

        // Expected raw-pixel bytes for an A4-ish page at this dpi. We
        // overestimate slightly (8.5 × 11.7 in) so progress doesn't hit
        // 100% mid-scan and stall visibly; final "done" jump to 100 comes
        // from the encode-complete report at the bottom.
        long expectedBytes = (long)(8.5 * 11.7 * p.Dpi * p.Dpi * 3);

        using var tiffStream = Pool.GetStream("scan-tiff");
        var stderrTask = proc.StandardError.ReadToEndAsync(ct);
        var buffer = new byte[64 * 1024];
        long totalRead = 0;
        int lastReportedPct = -5;  // ensures the first real report fires
        while (true)
        {
            var n = await proc.StandardOutput.BaseStream.ReadAsync(buffer, ct);
            if (n <= 0) break;
            await tiffStream.WriteAsync(buffer.AsMemory(0, n), ct);
            totalRead += n;
            if (progress is not null && expectedBytes > 0)
            {
                // Cap at 99% — 100% belongs to "encode complete", so the
                // UI never says 100% while the daemon is still working.
                var pct = (int)Math.Min(99, totalRead * 100 / expectedBytes);
                if (pct - lastReportedPct >= 5)
                {
                    progress.Report(pct);
                    lastReportedPct = pct;
                }
            }
        }
        await proc.WaitForExitAsync(ct);
        var stderr = await stderrTask;
        scanT.Stop();

        if (proc.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"scanimage exited {proc.ExitCode}: {stderr.Trim()}");
        }

        var tiffBytes = tiffStream.Length;
        tiffStream.Position = 0;
        var tiffThroughput = scanT.Elapsed.TotalSeconds > 0
            ? tiffBytes / 1024.0 / 1024.0 / scanT.Elapsed.TotalSeconds
            : 0;
        _logger.LogInformation(
            "scanimage done: {Bytes} in {Elapsed:F2}s ({Mbps:F1} MB/s) rss={Rss} heap={Heap}",
            Fmt(tiffBytes), scanT.Elapsed.TotalSeconds, tiffThroughput,
            Fmt(MemRss()), Fmt(MemManaged()));

        // ── Step 2: TIFF → Image<Rgb24> decode ─────────────────────────────
        // Image.Load reads the whole TIFF into one decoded bitmap
        // (~3 bytes/pixel). 200 dpi A4 color ≈ 22 MB, 600 dpi ≈ 200 MB.
        // ImageSharp uses ArrayPool under the hood so managed-heap spike
        // is smaller than raw allocation would suggest.
        var decodeT = Stopwatch.StartNew();
        using var image = await Image.LoadAsync<Rgb24>(tiffStream, ct);
        decodeT.Stop();
        var pixelBytes = (long)image.Width * image.Height * 3;
        _logger.LogInformation(
            "decode done: {W}x{H} ({Px} decoded) in {Elapsed:F2}s rss={Rss} heap={Heap}",
            image.Width, image.Height, Fmt(pixelBytes),
            decodeT.Elapsed.TotalSeconds,
            Fmt(MemRss()), Fmt(MemManaged()));

        // ── Step 3: Image → target format re-encode ────────────────────────
        var (contentType, ext) = p.Format switch
        {
            ScanFormat.Png => ("image/png", "png"),
            ScanFormat.Tiff => ("image/tiff", "tiff"),
            ScanFormat.Webp => ("image/webp", "webp"),
            _ => ("image/jpeg", "jpg"),
        };
        var outStream = Pool.GetStream("scan-encoded");
        var encodeT = Stopwatch.StartNew();
        try
        {
            switch (p.Format)
            {
                case ScanFormat.Png:
                    // BestCompression = zlib level 9. Extra ~300 ms on
                    // a 200 dpi page vs Default but saves 15-20%.
                    // Re-encode is offline from the scanner so this
                    // doesn't back-pressure anything.
                    await image.SaveAsPngAsync(outStream, new PngEncoder
                    {
                        CompressionLevel = PngCompressionLevel.BestCompression,
                    }, ct);
                    break;

                case ScanFormat.Tiff:
                    // Deflate (zlib) — best lossless ratio that modern
                    // viewers actually understand. LZW is the even-older
                    // ultra-compat fallback but ~20% worse compression.
                    // Preview / Photos / GIMP / ImageMagick / Photoshop
                    // (CS4+) all read Deflate-TIFF.
                    await image.SaveAsTiffAsync(outStream, new TiffEncoder
                    {
                        Compression = TiffCompression.Deflate,
                    }, ct);
                    break;

                case ScanFormat.Webp:
                    // Lossless WebP — typically ~55-65% the size of a
                    // level-9 PNG on document scans, zero quality loss,
                    // and Telegram renders inline previews for WebP
                    // attachments. FileFormat=Lossless plus a middle-of-
                    // road encode method (4/6) balances compression vs
                    // encode-time on the A72. Method 6 would squeeze
                    // another ~5% but triples encode time — not worth
                    // it at scanner feed rates.
                    await image.SaveAsWebpAsync(outStream, new WebpEncoder
                    {
                        FileFormat = WebpFileFormatType.Lossless,
                        Method = WebpEncodingMethod.Default,
                    }, ct);
                    break;

                default:
                    // Q=85 + 4:4:4 chroma (no subsampling). 4:2:0 is the
                    // JPEG default but smears color in text — terrible
                    // for document scans. The doubled chroma bandwidth
                    // costs us maybe 30% more bytes but keeps glyph
                    // edges crisp.
                    await image.SaveAsJpegAsync(outStream, new JpegEncoder
                    {
                        Quality = JpegQuality,
                        ColorType = JpegEncodingColor.YCbCrRatio444,
                    }, ct);
                    break;
            }
            encodeT.Stop();

            outStream.Position = 0;
            var outBytes = outStream.Length;
            var encodeThroughput = encodeT.Elapsed.TotalSeconds > 0
                ? pixelBytes / 1024.0 / 1024.0 / encodeT.Elapsed.TotalSeconds
                : 0;
            _logger.LogInformation(
                "encode done: {Out} {Ext} ({Pct}% of raw) in {Elapsed:F2}s " +
                "({Mbps:F1} MB/s pixels) rss={Rss} heap={Heap}",
                Fmt(outBytes), ext,
                tiffBytes > 0 ? 100L * outBytes / tiffBytes : 0,
                encodeT.Elapsed.TotalSeconds, encodeThroughput,
                Fmt(MemRss()), Fmt(MemManaged()));

            total.Stop();
            _logger.LogInformation(
                "scan total: {Elapsed:F2}s (scanimage={Scan:F2}s decode={Dec:F2}s encode={Enc:F2}s)",
                total.Elapsed.TotalSeconds,
                scanT.Elapsed.TotalSeconds,
                decodeT.Elapsed.TotalSeconds,
                encodeT.Elapsed.TotalSeconds);
            // Final 100% belongs here — everything above it is "not done yet".
            progress?.Report(100);

            return new Result(outStream, contentType, ext);
        }
        catch
        {
            outStream.Dispose();
            throw;
        }
    }
}
