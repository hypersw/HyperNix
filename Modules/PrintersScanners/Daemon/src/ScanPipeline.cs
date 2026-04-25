using System.Diagnostics;
using Microsoft.IO;
using PrintScan.Shared;
using SixLabors.Fonts;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Drawing;
using SixLabors.ImageSharp.Drawing.Processing;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Formats.Webp;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

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

    public record Variant(
        RecyclableMemoryStream Data,
        RecyclableMemoryStream Thumbnail,
        string ContentType,
        string FileName,
        string FileExtension,
        bool IsLossless);

    // Telegram's sendDocument thumbnail spec: JPEG, ≤320×320, ≤200 KB.
    // 320×320 at Q=80 is typically 15–30 KB for scanned pages, well under
    // the cap. Overlay strip adds a few KB for the black bar + text glyphs.
    private const int ThumbMaxSide = 320;
    private const int ThumbJpegQuality = 80;
    private const float OverlayFontSize = 14f;
    private const float OverlayBarHeight = 22f;

    // Lazily-loaded overlay font. ToolPaths.OverlayFont points at a
    // DejaVu Sans TTF in the nix store (injected at build time by
    // package.nix — see ToolPaths.g.cs). Pure managed, no fontconfig
    // lookup at runtime.
    private static readonly Lazy<Font> _overlayFont = new(() =>
    {
        var fonts = new FontCollection();
        var family = fonts.Add(ToolPaths.OverlayFont);
        return family.CreateFont(OverlayFontSize, FontStyle.Regular);
    });

    private static string FormatLabel(ScanFormat f) => f switch
    {
        ScanFormat.Jpeg         => "JPG",
        ScanFormat.Png          => "PNG",
        ScanFormat.WebpLossless => "WEBP-LL",
        ScanFormat.WebpLossy    => "WEBP",
        _ => f.ToString(),
    };

    // Filename convention: Scan.<ISO-date>.<ISO-time>.[Lossless.]<ext>
    // Local time (what the user reads on their phone). The "Lossless."
    // infix only appears on lossless variants so lossy and lossless
    // WebP of the same scan don't collide on .webp.
    private static string BuildFileName(string ext, bool isLossless, DateTime stamp) =>
        $"Scan.{stamp:yyyy-MM-dd.HH-mm-ss}.{(isLossless ? "Lossless." : "")}{ext}";

    private static (string contentType, string ext, bool lossless) FormatMeta(ScanFormat f) => f switch
    {
        ScanFormat.Jpeg         => ("image/jpeg", "jpg",  false),
        ScanFormat.Png          => ("image/png",  "png",  true),
        ScanFormat.WebpLossless => ("image/webp", "webp", true),
        ScanFormat.WebpLossy    => ("image/webp", "webp", false),
        _ => throw new ArgumentOutOfRangeException(nameof(f), f, "not a single ScanFormat flag"),
    };

    /// <summary>
    /// Scan synchronously, decode, re-encode into every requested format
    /// (p.Format is a bitmask), return one Variant per format. Callers
    /// own the streams and must dispose them. Throws on non-zero exit
    /// or spawn failure. Optional <paramref name="progress"/> is reported
    /// 0..99 while scanimage is streaming bytes (estimated from expected
    /// A4-page size — rough but close enough for a UI bar), and then 100
    /// when the last encode completes.
    /// </summary>
    public async Task<IReadOnlyList<Variant>> ScanAsync(
        ScanParams p, int seq, IProgress<int>? progress, CancellationToken ct)
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

        // ── Step 3: Image → N target formats (one per set bit) ─────────────
        // Flatten the bitmask into an ordered list of individual formats.
        // Fallback to Jpeg if caller somehow sent None (defensive; the
        // bot UI enforces at-least-one).
        var formats = new List<ScanFormat>();
        if ((p.Format & ScanFormat.Jpeg)         != 0) formats.Add(ScanFormat.Jpeg);
        if ((p.Format & ScanFormat.Png)          != 0) formats.Add(ScanFormat.Png);
        if ((p.Format & ScanFormat.WebpLossless) != 0) formats.Add(ScanFormat.WebpLossless);
        if ((p.Format & ScanFormat.WebpLossy)    != 0) formats.Add(ScanFormat.WebpLossy);
        if (formats.Count == 0) formats.Add(ScanFormat.Jpeg);

        // Only label format in overlays when the user selected >1 format
        // (otherwise the label is redundant — the filename extension
        // already tells you which format this is).
        var labelFormat = formats.Count > 1;

        var stamp = DateTime.Now;
        var results = new List<Variant>(formats.Count);
        var encodeTotal = Stopwatch.StartNew();
        try
        {
            foreach (var fmt in formats)
            {
                var (contentType, ext, lossless) = FormatMeta(fmt);
                var outStream = Pool.GetStream("scan-encoded");
                RecyclableMemoryStream? thumbStream = null;
                var encodeT = Stopwatch.StartNew();
                try
                {
                    switch (fmt)
                    {
                        case ScanFormat.Png:
                            // BestCompression = zlib level 9. Extra ~300 ms on
                            // a 200 dpi page vs Default but saves 15-20%.
                            await image.SaveAsPngAsync(outStream, new PngEncoder
                            {
                                CompressionLevel = PngCompressionLevel.BestCompression,
                            }, ct);
                            break;

                        case ScanFormat.WebpLossless:
                            // Lossless WebP — typically ~55-65% the size of
                            // a level-9 PNG on document scans, zero quality
                            // loss, Telegram renders inline previews.
                            await image.SaveAsWebpAsync(outStream, new WebpEncoder
                            {
                                FileFormat = WebpFileFormatType.Lossless,
                                Method = WebpEncodingMethod.Default,
                            }, ct);
                            break;

                        case ScanFormat.WebpLossy:
                            // Lossy WebP at Q=85 — same "no knob" rationale
                            // as JPEG. Typically ~30% smaller than JPEG Q=85
                            // for equal perceived quality on documents, with
                            // better handling of text edges (no 8×8 DCT
                            // ringing).
                            await image.SaveAsWebpAsync(outStream, new WebpEncoder
                            {
                                FileFormat = WebpFileFormatType.Lossy,
                                Quality = JpegQuality,
                                Method = WebpEncodingMethod.Default,
                            }, ct);
                            break;

                        default:  // ScanFormat.Jpeg
                            // Q=85 + 4:4:4 chroma. 4:2:0 default smears color
                            // in text. +30% bytes vs 4:2:0 but crisp glyphs.
                            await image.SaveAsJpegAsync(outStream, new JpegEncoder
                            {
                                Quality = JpegQuality,
                                ColorType = JpegEncodingColor.YCbCrRatio444,
                            }, ct);
                            break;
                    }
                    encodeT.Stop();
                    outStream.Position = 0;

                    // Per-variant thumbnail with bottom-bar overlay.
                    // Text "dpi · scan #N" (+ " · WEBP-LL"/etc when multi-
                    // format). DejaVu Sans at 14pt on a 22px black strip.
                    thumbStream = await MakeThumbnailAsync(
                        image, p.Dpi, seq, fmt, labelFormat, ct);

                    var fileName = BuildFileName(ext, lossless, stamp);
                    results.Add(new Variant(
                        outStream, thumbStream, contentType, fileName, ext, lossless));

                    _logger.LogInformation(
                        "encode {Fmt}: {Out} ({Pct}% of raw) + {ThumbKb}KB thumb " +
                        "in {Elapsed:F2}s rss={Rss} heap={Heap}",
                        fmt, Fmt(outStream.Length),
                        tiffBytes > 0 ? 100L * outStream.Length / tiffBytes : 0,
                        thumbStream.Length / 1024,
                        encodeT.Elapsed.TotalSeconds,
                        Fmt(MemRss()), Fmt(MemManaged()));
                }
                catch
                {
                    outStream.Dispose();
                    thumbStream?.Dispose();
                    throw;
                }
            }
            encodeTotal.Stop();

            total.Stop();
            _logger.LogInformation(
                "scan total: {Elapsed:F2}s ({NFmt} formats) — " +
                "scanimage={Scan:F2}s decode={Dec:F2}s encode={Enc:F2}s",
                total.Elapsed.TotalSeconds, formats.Count,
                scanT.Elapsed.TotalSeconds,
                decodeT.Elapsed.TotalSeconds,
                encodeTotal.Elapsed.TotalSeconds);
            progress?.Report(100);

            return results;
        }
        catch
        {
            foreach (var v in results)
            {
                v.Data.Dispose();
                v.Thumbnail.Dispose();
            }
            throw;
        }
    }

    /// <summary>
    /// Clone → resize to 320×320 max → draw black bottom-strip with
    /// white label → encode JPEG. Returns a stream rewound for reading.
    /// </summary>
    private async Task<RecyclableMemoryStream> MakeThumbnailAsync(
        Image<Rgb24> source, int dpi, int seq, ScanFormat fmt, bool labelFormat,
        CancellationToken ct)
    {
        using var thumb = source.Clone(ctx => ctx.Resize(new ResizeOptions
        {
            Mode = ResizeMode.Max,
            Size = new Size(ThumbMaxSide, ThumbMaxSide),
        }));

        var label = labelFormat
            ? $"{dpi} dpi · scan #{seq} · {FormatLabel(fmt)}"
            : $"{dpi} dpi · scan #{seq}";

        thumb.Mutate(ctx =>
        {
            var barY = thumb.Height - OverlayBarHeight;
            ctx.Fill(Color.Black,
                new RectangularPolygon(0, barY, thumb.Width, OverlayBarHeight));
            ctx.DrawText(label, _overlayFont.Value, Color.White,
                new PointF(8, barY + 3));
        });

        var stream = Pool.GetStream("scan-thumb");
        await thumb.SaveAsJpegAsync(stream, new JpegEncoder { Quality = ThumbJpegQuality }, ct);
        stream.Position = 0;
        return stream;
    }
}
