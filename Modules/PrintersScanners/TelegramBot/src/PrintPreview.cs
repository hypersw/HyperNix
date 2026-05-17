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
/// inputs to 600-dpi-at-A4, convert to grayscale, then wrap into a
/// single-page PDF whose pixel grid lines up with the HP P2015n's
/// 600 dpi mechanical engine resolution. With <c>/Interpolate false</c>
/// on the image XObject (set by <see cref="PrintPdfWrap"/>),
/// Ghostscript inside CUPS does an identity nearest-neighbor map
/// at the rasterizer and the foo2zjs filter passes the bitmap to
/// the printer engine pixel-for-pixel — no double-resample, no
/// CUPS-bilinear softening, just our Lanczos3 + RET edge enhancement
/// at the engine.
///
/// Preserves the image's *physical* dimensions: when we upscale the
/// pixel count by N, we proportionally bump the dpi metadata, so the
/// final inches-on-paper that <see cref="PrintPdfWrap"/> computes
/// from px / dpi stay the same. Otherwise 1:1 mode would silently
/// start printing at 5× the user's intended size.
/// </summary>
/// <summary>
/// Two broad content categories that route to different upscalers.
/// Photos benefit from sinc-windowed Lanczos3 (smooth tones, mild
/// detail enhancement); graphics — line art, cartoons, charts,
/// diagrams, scanned coloring books, screenshots — fare poorly
/// on Lanczos3 (halos around hard edges, soft strokes) and want
/// a shape-aware or neural upscaler instead. realesr-animevideov3
/// is the practical pick for the latter on a Pi-class device.
/// </summary>
public enum ContentClass { Photo, Graphics }

/// <summary>Stats from <see cref="PrintPreprocess.Classify"/>.</summary>
public sealed record ClassifierStats(
    int UniqueQuantisedColours,
    double EdgeDensity);

/// User's manual override for the upscaler-routing decision. Auto
/// uses the classifier's verdict; Photo / Graphics force the
/// respective path regardless of classifier.
public enum UpscalerChoice
{
    Auto,
    Photo,
    Graphics,
}

public static class PrintPreprocess
{
    /// <summary>
    /// Classify an incoming image as photo-like or graphics-like
    /// using two cheap heuristics combined: unique-colour count
    /// (line art / charts have far fewer distinct colours than
    /// continuous-tone photos) AND adjacent-pixel edge density
    /// (sharp vector edges have many large pixel-to-pixel deltas;
    /// continuous-tone photos have smooth gradients with very few).
    /// Combining both signals catches near-monochrome photos
    /// (sunsets, B&amp;W portraits) that the colour-count heuristic
    /// alone would mis-classify.
    /// </summary>
    public static (ContentClass Class, ClassifierStats Stats) Classify(Image<Rgb24> image)
    {
        // Constant-cost: downsample to a bounded thumbnail before
        // counting. Aspect-preserving so we don't bias the colour
        // population.
        const int ThumbMax = 256;
        using var thumb = image.Clone(c => c.Resize(new ResizeOptions
        {
            Mode = ResizeMode.Max,
            Size = new Size(ThumbMax, ThumbMax),
            Sampler = KnownResamplers.Box,
        }));

        // 4 bits per channel = 4096 possible quantised RGB values.
        var seen = new HashSet<int>();
        long edgePixelCount = 0;
        long pairCount = 0;
        // Edge threshold: a pixel-to-pixel max-channel difference
        // ≥ 64 (out of 255) is a "hard" edge. Photos virtually
        // never produce this; line art does on every stroke.
        const int EdgeMagnitudeThreshold = 64;

        thumb.ProcessPixelRows(accessor =>
        {
            for (int y = 0; y < accessor.Height; y++)
            {
                var row = accessor.GetRowSpan(y);
                for (int x = 0; x < row.Length; x++)
                {
                    var p = row[x];
                    var q = ((p.R >> 4) << 8) | ((p.G >> 4) << 4) | (p.B >> 4);
                    seen.Add(q);
                    if (x > 0)
                    {
                        var prev = row[x - 1];
                        var dr = Math.Abs(p.R - prev.R);
                        var dg = Math.Abs(p.G - prev.G);
                        var db = Math.Abs(p.B - prev.B);
                        if (Math.Max(dr, Math.Max(dg, db)) >= EdgeMagnitudeThreshold)
                            edgePixelCount++;
                        pairCount++;
                    }
                }
            }
        });

        var colourCount = seen.Count;
        var edgeDensity = pairCount > 0 ? (double)edgePixelCount / pairCount : 0.0;

        // Combined heuristic — see PLAN.md for thresholds rationale.
        // The "ambiguous" middle ground falls back to Photo as the
        // safe default: Lanczos3 on graphics is soft but not
        // hallucinatory; neural-on-photos can produce uncanny
        // textures.
        var fewColours  = colourCount <= 512;
        var manyColours = colourCount >= 1024;
        var sharpEdges  = edgeDensity >= 0.05;
        var smoothEdges = edgeDensity <= 0.02;

        ContentClass cls;
        if (fewColours && sharpEdges)            cls = ContentClass.Graphics;
        else if (manyColours || smoothEdges)     cls = ContentClass.Photo;
        else                                     cls = ContentClass.Photo;

        return (cls, new ClassifierStats(colourCount, edgeDensity));
    }

    /// Target dpi at full paper size. 600 dpi matches the HP P2015n's
    /// 600-dpi mechanical engine — the rasterizer's output grid will
    /// then map 1:1 to our pixels, so /Interpolate false in the PDF
    /// gives identity passthrough rather than nearest-neighbor jaggies.
    /// Memory: 600-dpi A4 grayscale = 4962×7016 px = 35 MB raw,
    /// comfortable on a Pi 4 (4 GB RAM); after FlateDecode in the
    /// PDF, the on-wire size is typically 5–15 MB depending on
    /// content entropy.
    private const int TargetDpi = 600;

    public sealed record Result(
        byte[] PdfBytes, int Width, int Height, int Dpi,
        ContentClass ContentClass,
        ClassifierStats ClassifierStats,
        UpscalerUsed Upscaler);

    public enum UpscalerUsed
    {
        /// Lanczos3 was used for the upscale. Either the source
        /// classified as Photo, or the user forced a Photo override,
        /// or the source already exceeded the target resolution
        /// (no upscale needed at all).
        Lanczos3,
        /// Real-ESRGAN (animevideov3) was used. Source classified
        /// as Graphics or user forced Graphics override.
        Neural,
        /// Source was Graphics-class and we tried Real-ESRGAN, but
        /// the renderer's neural endpoint failed (Vulkan unavail
        /// AND CPU also failed, or renderer unreachable). Fell
        /// back to Lanczos3 — the print still went through but
        /// the user should know quality is lower than expected.
        NeuralFailedFellBackToLanczos,
    }

    /// <summary>
    /// Take the raw image bytes the bot received, return print-ready
    /// PDF bytes. For Photo content (or user override): Lanczos3
    /// upscale + grayscale + PDF wrap. For Graphics content
    /// (animevideov3-style line art / cartoons / charts): route
    /// through the renderer's neural upscaler first, then a final
    /// Lanczos3 pass to hit the 600 dpi A4 target if Real-ESRGAN's
    /// 4× output is still under the engine's resolution. Renderer
    /// failure is non-fatal: caller logs at Error level and the
    /// path falls through to plain Lanczos3 so the print still
    /// goes through.
    /// </summary>
    public static async Task<Result> ProcessForPrintAsync(
        byte[] sourceBytes,
        PrintScaleMode scale, PrintOrientation orientation,
        double paperShortInches, double paperLongInches,
        PrintableMargins margins,
        UpscalerChoice upscalerChoice,
        Func<byte[], string, int, double, CancellationToken, Task<byte[]?>>? neuralUpscaler,
        string fileName,
        CancellationToken ct)
    {
        // Source metadata read (DPI in particular) needs to happen
        // BEFORE the neural upscale so we can pass it through to the
        // upscaler client — which uses it to stamp the right pHYs
        // chunk on the realesrgan-ncnn output. Image.IdentifyAsync
        // reads metadata without a full pixel decode — cheap.
        // Distinct from the post-neural `sourceDpi` declared further
        // down (which reads the working-image's metadata after the
        // upscale; same value after our stamp, but conceptually the
        // "input to whatever the Lanczos finish does").
        var sourceInfo = await Image.IdentifyAsync(
            new MemoryStream(sourceBytes, writable: false), ct);
        var origHRes = sourceInfo.Metadata.HorizontalResolution;
        var origVRes = sourceInfo.Metadata.VerticalResolution;
        // Fallback to 96 dpi (Windows screenshot default, ImageSharp's
        // own PNG default) when the source has no pHYs at all. Matches
        // PendingPrint.NoMetadataFallbackDpi so the "1:1 fits?" badge
        // in the UI and the preview-pipeline assumption agree.
        var originalSourceDpi = (origHRes > 0 && origVRes > 0)
            ? Math.Min(origHRes, origVRes)
            : 96.0;

        // Classifier reads a quick downsampled thumbnail of the
        // source to decide the upscaler route. Disposed before we
        // open the working pipeline image so we don't carry two
        // decodes simultaneously.
        ContentClass autoClass;
        ClassifierStats classStats;
        using (var classifierImage = await Image.LoadAsync<Rgb24>(
            new MemoryStream(sourceBytes, writable: false), ct))
        {
            (autoClass, classStats) = Classify(classifierImage);
        }
        var effectiveClass = upscalerChoice switch
        {
            UpscalerChoice.Photo    => ContentClass.Photo,
            UpscalerChoice.Graphics => ContentClass.Graphics,
            _ => autoClass,
        };

        // Source bytes that'll be Lanczos3'd to the final 600 dpi
        // target. For Graphics: run Real-ESRGAN ×4 once, Lanczos3
        // from there. For Photo: skip neural entirely. The next
        // commit replaces this single attempt with a multi-pass
        // loop so that a small enough input can be brought up to
        // the engine grid before the Lanczos finish.
        byte[] workingBytes = sourceBytes;
        UpscalerUsed upscalerUsed = UpscalerUsed.Lanczos3;
        if (effectiveClass == ContentClass.Graphics && neuralUpscaler is not null)
        {
            var passBytes = await neuralUpscaler(
                sourceBytes, fileName, 4, originalSourceDpi, ct);
            if (passBytes is null)
            {
                upscalerUsed = UpscalerUsed.NeuralFailedFellBackToLanczos;
            }
            else
            {
                workingBytes = passBytes;
                upscalerUsed = UpscalerUsed.Neural;
            }
        }

        // Open the (possibly upscaled) working bytes. After our
        // RendererClient stamp, this image's metadata has the
        // correct post-upscale DPI even if realesrgan-ncnn dropped
        // pHYs from its output.
        using var rgbImage = await Image.LoadAsync<Rgb24>(
            new MemoryStream(workingBytes, writable: false), ct);
        var contentClass = effectiveClass;

        // DPI on the working image — for Graphics it's
        // originalSourceDpi × neuralScale (post-stamp); for Photo
        // it's whatever the source had. Defensive fallback to the
        // original DPI we measured if the working image's metadata
        // somehow went missing.
        var workingHRes = rgbImage.Metadata.HorizontalResolution;
        var workingVRes = rgbImage.Metadata.VerticalResolution;
        var workingDpi  = (workingHRes > 0 && workingVRes > 0)
            ? Math.Min(workingHRes, workingVRes)
            : originalSourceDpi;

        // Auto-orientation: source's wider-than-tall hint goes to
        // landscape, else portrait. Resolved once here; the canvas
        // itself is always portrait-shaped (the printer feeds paper
        // short-edge-first, regardless of how the content is laid
        // out within the bitmap).
        var effectiveOrient = orientation switch
        {
            PrintOrientation.Auto =>
                rgbImage.Width > rgbImage.Height
                    ? PrintOrientation.Landscape
                    : PrintOrientation.Portrait,
            var o => o,
        };

        // Engine pixel grid for the FULL paper. This is the canvas
        // we'll composite the content into; what CUPS / Ghostscript
        // / foo2zjs ultimately receive. Note: short × long, in the
        // paper's natural portrait orientation. Same bitmap shape
        // whether the user picked portrait or landscape — landscape
        // is realised by rotating the CONTENT 90° inside the canvas.
        var canvasW = (int)Math.Round(paperShortInches * TargetDpi);
        var canvasH = (int)Math.Round(paperLongInches  * TargetDpi);

        // Printable rectangle in engine pixels — used for Fit / Fill
        // sizing decisions. Output bitmap stays at canvasW × canvasH
        // regardless (with white-fill in the margin areas); the
        // printable rect just bounds where content placement is
        // allowed to land. Sub-px margin shifts (4.23 mm rounds to
        // 99.92 px; rounded to 100) stay confined to this sizing
        // math — they never touch the bitmap's pixel grid.
        var marginLPx = (int)Math.Round(margins.LeftMm   * TargetDpi / 25.4);
        var marginRPx = (int)Math.Round(margins.RightMm  * TargetDpi / 25.4);
        var marginTPx = (int)Math.Round(margins.TopMm    * TargetDpi / 25.4);
        var marginBPx = (int)Math.Round(margins.BottomMm * TargetDpi / 25.4);
        var printableW = canvasW - marginLPx - marginRPx;
        var printableH = canvasH - marginTPx - marginBPx;

        // Pre-rotate the working image for landscape so its long axis
        // ends up across the canvas's long axis. After rotation:
        //   rgbImage.Width  → was source's height
        //   rgbImage.Height → was source's width
        // workingDpi is orientation-invariant (a 300-dpi image is
        // 300 px/in on either axis regardless of which way is up).
        if (effectiveOrient == PrintOrientation.Landscape)
            rgbImage.Mutate(c => c.Rotate(RotateMode.Rotate90));

        var srcW = rgbImage.Width;
        var srcH = rgbImage.Height;

        // Compute target CONTENT rectangle (in canvas pixels). Each
        // mode produces integer dimensions — no Math.Round on a
        // fractional scale-factor, the integers ARE the resize
        // target. The Lanczos3 step below uses whatever sample ratio
        // these integers imply.
        //   - 1:1   : source's declared physical size × engine DPI
        //   - Fit   : largest rect inside printable, source aspect
        //   - Fill  : smallest rect covering printable, source aspect
        int contentW, contentH;
        switch (scale)
        {
            case PrintScaleMode.OneToOne:
                contentW = (int)Math.Round(srcW * (double)TargetDpi / workingDpi);
                contentH = (int)Math.Round(srcH * (double)TargetDpi / workingDpi);
                break;
            case PrintScaleMode.Fill:
            {
                // smallest rect covering printable while preserving
                // source aspect: use the LARGER of the two axis
                // scales (the one that needs more enlargement wins).
                var fillScale = Math.Max(
                    (double)printableW / srcW,
                    (double)printableH / srcH);
                contentW = (int)Math.Round(srcW * fillScale);
                contentH = (int)Math.Round(srcH * fillScale);
                break;
            }
            default: // Fit
            {
                var fitScale = Math.Min(
                    (double)printableW / srcW,
                    (double)printableH / srcH);
                contentW = (int)Math.Round(srcW * fitScale);
                contentH = (int)Math.Round(srcH * fitScale);
                break;
            }
        }

        // Lanczos3 resize the rotated source to the exact integer
        // content dimensions, then grayscale in-place. ResizeMode
        // Stretch because we've already locked the target W×H
        // ourselves and don't want ImageSharp's own aspect-handling
        // to second-guess (which it does in Max / Pad modes).
        rgbImage.Mutate(c => c
            .Resize(new ResizeOptions
            {
                Mode = ResizeMode.Stretch,
                Size = new Size(contentW, contentH),
                Sampler = KnownResamplers.Lanczos3,
            })
            .Grayscale());
        using var grayContent = rgbImage.CloneAs<L8>();

        // Engine-grid canvas, white (L8=255). Composite the grayscale
        // content at centre. DrawImage clips the source where it
        // exceeds canvas bounds — the 1:1-oversize case becomes a
        // centre-crop, the Fill-overflow case becomes a clip at
        // canvas edges (paper edges, beyond non-printable margins).
        using var canvas = new Image<L8>(canvasW, canvasH, new L8(255));
        var offsetX = (canvasW - contentW) / 2;
        var offsetY = (canvasH - contentH) / 2;
        canvas.Mutate(c =>
            c.DrawImage(grayContent, new Point(offsetX, offsetY), 1.0f));
        canvas.Metadata.HorizontalResolution = TargetDpi;
        canvas.Metadata.VerticalResolution   = TargetDpi;
        canvas.Metadata.ResolutionUnits =
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerInch;

        // PrintPdfWrap now just wraps an already-engine-grid bitmap.
        // No cm-matrix scaling, no rotation, no clip — the bitmap
        // has all of that baked in.
        var pdfBytes = PrintPdfWrap.WrapImage(
            canvas, paperShortInches, paperLongInches);

        return new Result(pdfBytes, canvasW, canvasH, TargetDpi,
            contentClass, classStats, upscalerUsed);
    }
}
