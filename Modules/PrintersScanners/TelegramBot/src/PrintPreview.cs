using PrintScan.Shared;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Drawing;
using SixLabors.ImageSharp.Drawing.Processing;
using SixLabors.ImageSharp.Formats.Png;
using SixLabors.ImageSharp.Formats.Webp;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

namespace PrintScan.TelegramBot;

/// <summary>
/// Compose "what would actually print" preview images. The user sees
/// the source image laid out on a paper-aspect canvas with the
/// non-printable margins drawn faintly, so they can tell at a glance
/// whether 1:1 would land postmark-sized vs page-filling, whether a
/// Fit-mode image leaves margins, whether Fill clips, etc.
///
/// Lives next to <see cref="ImagePipeline"/> but separate because
/// the responsibilities don't overlap — that one transforms scanner
/// output into uploadable variants, this one synthesises a UX preview
/// out of an already-staged document.
/// </summary>
public static class PrintPreview
{
    /// Long-axis canvas size in pixels. 700 px gives Telegram a
    /// crisp preview at typical phone display sizes without paying
    /// for a megapixel-class image we'd just have to send N times
    /// per toggle.
    private const int CanvasLongPx = 700;

    /// Faint gray for the non-printable strip — signals "this part
    /// won't actually print" without overpowering the content.
    private static readonly Color MarginFill   = Color.FromRgb(0xee, 0xee, 0xee);
    private static readonly Color MarginEdge   = Color.FromRgb(0xcc, 0xcc, 0xcc);
    private static readonly Color PaperBg      = Color.White;

    private const double InchesPerMm = 1.0 / 25.4;

    /// Container for the composed preview. Bytes are encoded as
    /// lossy WebP at Q=80 — substantially smaller than PNG, which
    /// matters when we re-send on every toggle. The printer is mono
    /// so we grayscale the source as part of composition; the
    /// preview is then both quicker to ship and accurately reflects
    /// what'll actually print (post-grayscale-conversion).
    public sealed record Result(byte[] WebpBytes, double FillPercent);

    /// <summary>
    /// Synthesise a preview PNG showing how <paramref name="sourceBytes"/>
    /// would land on the paper with the active scale / orientation
    /// settings. Returns the encoded PNG and the percent of the
    /// physical page area the image's content would cover.
    /// </summary>
    public static async Task<Result> ComposeImageAsync(
        byte[] sourceBytes, PendingPrint p, BotPrintSession s,
        CancellationToken ct)
    {
        using var source = await Image.LoadAsync<Rgb24>(
            new MemoryStream(sourceBytes, writable: false), ct);
        return Compose(source, p, s);
    }

    private static Result Compose(Image<Rgb24> source, PendingPrint p, BotPrintSession s)
    {
        // Resolve the effective orientation we'd actually use.
        var effectiveOrient = p.Orientation == PrintOrientation.Auto
            ? p.AutoSuggestedOrientation
            : p.Orientation;

        // Canvas dimensions, oriented to match the chosen page
        // orientation. A4 portrait: short axis horizontal, long
        // axis vertical (canvas is taller than wide).
        var paperShort = p.PaperShortInches;
        var paperLong  = p.PaperLongInches;
        int canvasW, canvasH;
        if (effectiveOrient == PrintOrientation.Landscape)
        {
            canvasW = CanvasLongPx;
            canvasH = (int)Math.Round(CanvasLongPx * paperShort / paperLong);
        }
        else
        {
            canvasH = CanvasLongPx;
            canvasW = (int)Math.Round(CanvasLongPx * paperShort / paperLong);
        }

        // Pixels per inch on the canvas (same for both axes since
        // we kept paper aspect).
        var pxPerInch = canvasH / (effectiveOrient == PrintOrientation.Landscape
            ? paperShort : paperLong);

        // Margins in canvas pixels, oriented to match the page.
        double mTop, mBottom, mLeft, mRight;
        if (effectiveOrient == PrintOrientation.Landscape)
        {
            // Page rotated 90°: paper's "left" margin (in portrait
            // sense) becomes the top in landscape, and so on.
            mTop    = s.Margins.LeftMm   * InchesPerMm * pxPerInch;
            mBottom = s.Margins.RightMm  * InchesPerMm * pxPerInch;
            mLeft   = s.Margins.BottomMm * InchesPerMm * pxPerInch;
            mRight  = s.Margins.TopMm    * InchesPerMm * pxPerInch;
        }
        else
        {
            mTop    = s.Margins.TopMm    * InchesPerMm * pxPerInch;
            mBottom = s.Margins.BottomMm * InchesPerMm * pxPerInch;
            mLeft   = s.Margins.LeftMm   * InchesPerMm * pxPerInch;
            mRight  = s.Margins.RightMm  * InchesPerMm * pxPerInch;
        }

        var printableX  = (float)mLeft;
        var printableY  = (float)mTop;
        var printableW  = (float)(canvasW - mLeft - mRight);
        var printableH  = (float)(canvasH - mTop  - mBottom);

        // Source size on canvas per scale mode.
        float drawX, drawY, drawW, drawH;
        switch (p.Scale)
        {
            case PrintScaleMode.OneToOne:
            {
                // Native dpi defines physical inches; convert to
                // canvas pixels. If dpi missing, treat as 96 dpi
                // (typical for screen-grabbed images) — there's no
                // good answer but at least it gives a representative
                // size rather than a guess at "huge or tiny".
                var dpi = p.Dpi ?? 96;
                var sourceWIn = source.Width / (double)dpi;
                var sourceHIn = source.Height / (double)dpi;
                drawW = (float)(sourceWIn * pxPerInch);
                drawH = (float)(sourceHIn * pxPerInch);
                // Centre on the paper (not on the printable area —
                // 1:1 is "place at native size"; visualising it
                // page-centred matches what most printers do for
                // borderless / centred jobs).
                drawX = (canvasW - drawW) / 2f;
                drawY = (canvasH - drawH) / 2f;
                break;
            }
            case PrintScaleMode.Fill:
            {
                // Cover printable area, may crop overflow on one axis.
                var sx = printableW / source.Width;
                var sy = printableH / source.Height;
                var s_ = Math.Max(sx, sy);
                drawW = source.Width * s_;
                drawH = source.Height * s_;
                drawX = printableX + (printableW - drawW) / 2f;
                drawY = printableY + (printableH - drawH) / 2f;
                break;
            }
            default: // Fit
            {
                var sx = printableW / source.Width;
                var sy = printableH / source.Height;
                var s_ = Math.Min(sx, sy);
                drawW = source.Width * s_;
                drawH = source.Height * s_;
                drawX = printableX + (printableW - drawW) / 2f;
                drawY = printableY + (printableH - drawH) / 2f;
                break;
            }
        }

        // Resize-and-grayscale the source up front so the preview
        // reflects what the printer will actually receive (P2015n is
        // mono — there is no colour print, ever, so showing the user
        // the colour version of their image is a lie). Lanczos3 is
        // the right resampler default for both photo and screen
        // content downscale; the Grayscale() pass uses BT.709 luma
        // weights which is what most printer drivers do too.
        var targetW = Math.Max(1, (int)Math.Round(drawW));
        var targetH = Math.Max(1, (int)Math.Round(drawH));
        using var scaledSource = source.Clone(ctx => ctx
            .Resize(new ResizeOptions
            {
                Mode = ResizeMode.Stretch,
                Size = new Size(targetW, targetH),
                Sampler = KnownResamplers.Lanczos3,
            })
            .Grayscale());

        using var canvas = new Image<Rgb24>(canvasW, canvasH);
        canvas.Mutate(ctx =>
        {
            // Paper background.
            ctx.Fill(PaperBg);

            // Non-printable margins as a faintly-shaded inset frame.
            // We fill the four border bands rather than the printable
            // area so the actual paper colour shows through where it
            // should.
            if (mTop > 0)
                ctx.Fill(MarginFill,
                    new RectangularPolygon(0, 0, canvasW, (float)mTop));
            if (mBottom > 0)
                ctx.Fill(MarginFill,
                    new RectangularPolygon(0, canvasH - (float)mBottom, canvasW, (float)mBottom));
            if (mLeft > 0)
                ctx.Fill(MarginFill,
                    new RectangularPolygon(0, (float)mTop, (float)mLeft, canvasH - (float)mTop - (float)mBottom));
            if (mRight > 0)
                ctx.Fill(MarginFill,
                    new RectangularPolygon(canvasW - (float)mRight, (float)mTop, (float)mRight, canvasH - (float)mTop - (float)mBottom));

            // Hairline around the printable rectangle so the boundary
            // is unambiguous even at small sizes.
            ctx.Draw(MarginEdge, 1f,
                new RectangularPolygon(printableX, printableY, printableW, printableH));

            // Stamp the (resized) source. Its canvas position may
            // be negative or extend past canvas bounds in 1:1 /
            // Fill — ImageSharp clips for us.
            ctx.DrawImage(scaledSource,
                new Point((int)Math.Round(drawX), (int)Math.Round(drawY)),
                opacity: 1f);
        });

        // Fill % = visible source area on canvas, divided by paper
        // (canvas) area. Clipped to canvas, so 1:1 oversize images
        // top out at 100 %.
        var visX1 = Math.Max(0f, drawX);
        var visY1 = Math.Max(0f, drawY);
        var visX2 = Math.Min(canvasW, drawX + drawW);
        var visY2 = Math.Min(canvasH, drawY + drawH);
        var visW = Math.Max(0f, visX2 - visX1);
        var visH = Math.Max(0f, visY2 - visY1);
        var fillPct = (visW * visH) / (double)(canvasW * canvasH) * 100.0;

        using var ms = new MemoryStream();
        canvas.SaveAsWebp(ms, new WebpEncoder
        {
            FileFormat = WebpFileFormatType.Lossy,
            Quality = 80,
            Method = WebpEncodingMethod.Default,
        });
        return new Result(ms.ToArray(), fillPct);
    }
}

/// <summary>
/// Preprocess an image upload for the printer: upscale low-pixel-count
/// inputs so CUPS' filter chain only ever has to *down*-scale (the
/// good direction) when fitting onto the page, then convert to
/// grayscale (the printer is mono — there is no colour). Lanczos3
/// for the resampler, since for the v1 we're going one-size-fits-all
/// per the agreed plan; per-content-type variants (line-art-aware
/// scalers, neural upscalers) are a follow-up once we've evaluated
/// the baseline visually.
///
/// Preserves the image's *physical* dimensions: when we upscale the
/// pixel count by N, we proportionally bump the dpi metadata, so the
/// final inches-on-paper that CUPS computes from "px / dpi" stay
/// the same. Otherwise 1:1 mode would silently start printing at
/// 5× the user's intended size.
/// </summary>
public static class PrintPreprocess
{
    /// Target dpi at full paper size. 300 dpi grayscale A4 = ~8.7 MB
    /// raw pixel data, comfortably inside the HP P2015n's 32 MB stock
    /// memory. 600 dpi would also fit (~17 MB) but adds substantial
    /// CPU on the Pi for the upscale; pick 300 as the safe default
    /// and revisit once we have hands-on output samples.
    private const int TargetDpi = 300;

    /// Padding factor above 1.0 — only upscale if the gain is >5%.
    /// Avoids re-encoding 4096×3072 photos that already exceed our
    /// 300 dpi A4 target on at least one axis.
    private const double MinUpscaleGain = 1.05;

    public sealed record Result(byte[] PngBytes, int Width, int Height, int Dpi);

    /// <summary>
    /// Take the raw image bytes the bot received, return PNG bytes
    /// to ship to the daemon. Lossless PNG keeps the upscaled pixels
    /// intact through the daemon → CUPS handoff; CUPS decodes once.
    /// </summary>
    public static async Task<Result> ProcessForPrintAsync(
        byte[] sourceBytes, double paperShortInches, double paperLongInches,
        CancellationToken ct)
    {
        using var image = await Image.LoadAsync<Rgb24>(
            new MemoryStream(sourceBytes, writable: false), ct);

        // Source dpi as declared in the file metadata, falling back
        // to a screen-typical 96 when it's missing (most tg-uploaded
        // photos / random web images). The fallback only matters for
        // 1:1 sizing; if a downstream user picks 1:1 on a
        // dpi-stripped Telegram photo, this is the educated guess
        // we use as the baseline.
        var hRes = image.Metadata.HorizontalResolution;
        var vRes = image.Metadata.VerticalResolution;
        var sourceDpi = (hRes > 0 && vRes > 0) ? Math.Min(hRes, vRes) : 96.0;

        // Target pixel size: paper at TargetDpi. Pre-upscaling to
        // this guarantees CUPS only ever down-samples for any Scale
        // mode (Fit fits inside, 1:1 stays well-resourced).
        var targetLongPx  = (int)Math.Round(paperLongInches  * TargetDpi);
        var targetShortPx = (int)Math.Round(paperShortInches * TargetDpi);

        var imgLong  = Math.Max(image.Width, image.Height);
        var imgShort = Math.Min(image.Width, image.Height);
        var scaleByLong  = (double)targetLongPx  / imgLong;
        var scaleByShort = (double)targetShortPx / imgShort;
        // Min of the two gives a uniform scale that hits the closer
        // axis exactly — guarantees both dimensions ≥ target without
        // overshooting one. (Math.Max would force both axes ≥ target
        // by overshooting one, doubling pixel cost for no quality
        // win since CUPS will downscale the surplus axis anyway.)
        var scale = Math.Min(scaleByLong, scaleByShort);

        int finalW = image.Width;
        int finalH = image.Height;
        double finalDpi = sourceDpi;
        if (scale > MinUpscaleGain)
        {
            finalW = (int)Math.Round(image.Width  * scale);
            finalH = (int)Math.Round(image.Height * scale);
            // dpi scales with the pixel count so physical inches
            // stay constant — a 300×300 px image at 100 dpi (3"×3")
            // upscaled to 900×900 px must report 300 dpi (still
            // 3"×3") or 1:1 mode breaks.
            finalDpi = sourceDpi * scale;
            image.Mutate(c => c
                .Resize(new ResizeOptions
                {
                    Mode = ResizeMode.Stretch,
                    Size = new Size(finalW, finalH),
                    Sampler = KnownResamplers.Lanczos3,
                })
                .Grayscale());
        }
        else
        {
            image.Mutate(c => c.Grayscale());
        }

        // Keep dpi metadata current so the daemon / CUPS sees the
        // right physical size.
        image.Metadata.HorizontalResolution = finalDpi;
        image.Metadata.VerticalResolution   = finalDpi;

        using var ms = new MemoryStream();
        // PNG-Level6 is the default; we use grayscale + zlib only,
        // no fancy filtering, which keeps encode time on a Pi
        // tolerable for ~3 MB output.
        await image.SaveAsPngAsync(ms, new PngEncoder
        {
            ColorType = PngColorType.Grayscale,
            BitDepth = PngBitDepth.Bit8,
            CompressionLevel = PngCompressionLevel.Level6,
        }, ct);
        return new Result(ms.ToArray(), finalW, finalH, (int)Math.Round(finalDpi));
    }
}
