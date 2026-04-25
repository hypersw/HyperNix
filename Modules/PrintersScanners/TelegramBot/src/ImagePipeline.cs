using Microsoft.Extensions.Logging;
using Microsoft.IO;
using SixLabors.Fonts;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Drawing;
using SixLabors.ImageSharp.Drawing.Processing;
using SixLabors.ImageSharp.Formats.Jpeg;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Formats.Webp;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

namespace PrintScan.TelegramBot;

/// <summary>
/// Bot-side imagery pipeline: takes the raw TIFF the daemon produced,
/// decodes it once, and emits one <see cref="EncodedVariant"/> per set
/// bit in the user's format mask, each with its own 320×320 inline
/// thumbnail (overlay-labelled with dpi/scan#/format). Everything lives
/// in memory and is released the moment the caller has uploaded it —
/// no on-disk staging, no daemon-side accumulation.
///
/// All ImageSharp deps are pure managed; no native libraries to ship.
/// </summary>
public sealed class ImagePipeline
{
    // 4 MB blocks, 16 MB cap. Larger than the daemon's pool because
    // a single decoded buffer at 600 dpi A4 can run ~100 MB; the pool
    // doesn't have to fit it whole, but bigger blocks reduce list
    // walks during the encode reads.
    private static readonly RecyclableMemoryStreamManager Pool = new(
        new RecyclableMemoryStreamManager.Options
        {
            BlockSize = 256 * 1024,
            LargeBufferMultiple = 1024 * 1024,
            MaximumBufferSize = 16 * 1024 * 1024,
            GenerateCallStacks = false,
            AggressiveBufferReturn = true,
        });

    private const int JpegQuality = 85;

    // Telegram sendDocument thumbnail spec: JPEG, ≤320×320, ≤200 KB.
    // 320×320 at Q=80 is typically 15-30 KB for scanned pages, well
    // under the cap. Overlay strip adds a few KB for the bar + glyphs.
    private const int ThumbMaxSide = 320;
    private const int ThumbJpegQuality = 80;
    private const float OverlayFontSize = 14f;
    private const float OverlayBarHeight = 22f;

    // Lazily-loaded overlay font. ToolPaths.OverlayFont points at a
    // DejaVu Sans TTF in the nix store (injected at build time by
    // package.nix — see ToolPaths.g.cs). Pure managed, no fontconfig
    // lookup at runtime.
    private static readonly Lazy<Font> OverlayFont = new(() =>
    {
        var fonts = new FontCollection();
        var family = fonts.Add(ToolPaths.OverlayFont);
        return family.CreateFont(OverlayFontSize, FontStyle.Regular);
    });

    private readonly ILogger<ImagePipeline> _logger;

    public ImagePipeline(ILogger<ImagePipeline> logger) { _logger = logger; }

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
    /// Decode the TIFF, encode every requested format (one per bit in
    /// <paramref name="formats"/>), and produce a per-variant overlay
    /// thumbnail. Returned variants are in flag order (Jpeg, Png,
    /// WebpLossless, WebpLossy). Throws if the TIFF can't be decoded.
    /// </summary>
    public async Task<IReadOnlyList<EncodedVariant>> ProcessAsync(
        Stream tiff, int dpi, int seq, ScanFormat formats, CancellationToken ct)
    {
        var formatList = new List<ScanFormat>();
        if ((formats & ScanFormat.Jpeg)         != 0) formatList.Add(ScanFormat.Jpeg);
        if ((formats & ScanFormat.Png)          != 0) formatList.Add(ScanFormat.Png);
        if ((formats & ScanFormat.WebpLossless) != 0) formatList.Add(ScanFormat.WebpLossless);
        if ((formats & ScanFormat.WebpLossy)    != 0) formatList.Add(ScanFormat.WebpLossy);
        if (formatList.Count == 0) formatList.Add(ScanFormat.Jpeg);

        var labelFormat = formatList.Count > 1;
        var stamp = DateTime.Now;

        using var image = await Image.LoadAsync<Rgb24>(tiff, ct);
        _logger.LogInformation(
            "decoded scan #{Seq}: {W}x{H} ({MB:F1} MB raw)",
            seq, image.Width, image.Height,
            (long)image.Width * image.Height * 3 / 1024.0 / 1024.0);

        var results = new List<EncodedVariant>(formatList.Count);
        try
        {
            foreach (var fmt in formatList)
            {
                var (contentType, ext, lossless) = FormatMeta(fmt);
                var fileName = BuildFileName(ext, lossless, stamp);

                // Encode body
                var data = Pool.GetStream("scan-encoded");
                try
                {
                    switch (fmt)
                    {
                        case ScanFormat.Png:
                            await image.SaveAsPngAsync(data, new PngEncoder
                            {
                                CompressionLevel = PngCompressionLevel.BestCompression,
                            }, ct);
                            break;
                        case ScanFormat.WebpLossless:
                            await image.SaveAsWebpAsync(data, new WebpEncoder
                            {
                                FileFormat = WebpFileFormatType.Lossless,
                                Method = WebpEncodingMethod.Default,
                            }, ct);
                            break;
                        case ScanFormat.WebpLossy:
                            await image.SaveAsWebpAsync(data, new WebpEncoder
                            {
                                FileFormat = WebpFileFormatType.Lossy,
                                Quality = JpegQuality,
                                Method = WebpEncodingMethod.Default,
                            }, ct);
                            break;
                        default: // Jpeg
                            await image.SaveAsJpegAsync(data, new JpegEncoder
                            {
                                Quality = JpegQuality,
                                ColorType = JpegEncodingColor.YCbCrRatio444,
                            }, ct);
                            break;
                    }
                    data.Position = 0;
                }
                catch
                {
                    data.Dispose();
                    throw;
                }

                // Per-variant thumbnail
                RecyclableMemoryStream thumb;
                try
                {
                    thumb = await MakeThumbnailAsync(image, dpi, seq, fmt, labelFormat, ct);
                }
                catch
                {
                    data.Dispose();
                    throw;
                }

                results.Add(new EncodedVariant(data, thumb, contentType, fileName));
                _logger.LogInformation(
                    "encoded scan #{Seq} {Fmt}: {Bytes} KB + {Thumb} KB thumb",
                    seq, fmt, data.Length / 1024, thumb.Length / 1024);
            }
            return results;
        }
        catch
        {
            foreach (var v in results) v.Dispose();
            throw;
        }
    }

    private static async Task<RecyclableMemoryStream> MakeThumbnailAsync(
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
            ctx.DrawText(label, OverlayFont.Value, Color.White,
                new PointF(8, barY + 3));
        });

        var stream = Pool.GetStream("scan-thumb");
        await thumb.SaveAsJpegAsync(stream, new JpegEncoder { Quality = ThumbJpegQuality }, ct);
        stream.Position = 0;
        return stream;
    }
}

/// <summary>
/// One encoded variant — full file plus its inline preview thumbnail.
/// Both streams are owned by the variant and disposed together.
/// </summary>
public sealed class EncodedVariant : IDisposable
{
    public RecyclableMemoryStream Data { get; }
    public RecyclableMemoryStream Thumbnail { get; }
    public string ContentType { get; }
    public string FileName { get; }

    public EncodedVariant(
        RecyclableMemoryStream data, RecyclableMemoryStream thumbnail,
        string contentType, string fileName)
    {
        Data = data; Thumbnail = thumbnail;
        ContentType = contentType; FileName = fileName;
    }

    public void Dispose() { Data.Dispose(); Thumbnail.Dispose(); }
}
