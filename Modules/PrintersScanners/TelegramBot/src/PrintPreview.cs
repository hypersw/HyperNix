using Microsoft.Extensions.Logging;
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
        // (source, name, scale, srcDpi, IProgress<double>?, ct) → Task<byte[]?>
        // IProgress<double> emits 0..100 over a single neural pass; this
        // function maps those into a global percent across however many
        // passes will fire, weighted by surface area (pass N's
        // contribution = 16^N units, see comment in the loop).
        Func<byte[], string, int, double, IProgress<double>?, CancellationToken, Task<byte[]?>>? neuralUpscaler,
        string fileName,
        Microsoft.Extensions.Logging.ILogger? logger,
        // Reports overall preprocess progress to the caller: int = 0..100
        // global percent across the whole preprocess pipeline; string =
        // optional stage detail (e.g. "neural pass 1 of 2"). Null when
        // not interested.
        Action<int, string?>? onProgress,
        CancellationToken ct)
    {
        // Step-log everything that happens. Print is operator-initiated
        // (one user, low volume, no PII concerns), so trading log
        // verbosity for full pipeline reconstructability from journal
        // is the right call — if a print looks wrong we want to be
        // able to tell which step compromised it without re-running.
        logger ??= Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance;
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
        // ImageMetaDpi.ReadMinDpi normalises whatever ImageSharp gives
        // us (raw pHYs value + ResolutionUnits) into dpi. Windows
        // screenshots emit pHYs with unit=ppm and value=3780 (= 96 dpi
        // × 39.37 in/m); without normalisation the preprocess sees
        // "3780 dpi" and the upscaler pHYs stamp comes out 39× too
        // high. Fallback to 96 dpi matches PendingPrint.NoMetadataFallbackDpi
        // so the "1:1 fits?" badge in the UI and the preview-pipeline
        // assumption agree on what an unstamped image is worth.
        var dpiMaybe = ImageMetaDpi.ReadMinDpi(sourceInfo.Metadata);
        var hasMetadataDpi = dpiMaybe is not null;
        var originalSourceDpi = dpiMaybe ?? 96.0;
        logger.LogInformation(
            "preprocess {File}: source {W}x{H} px, dpi={Dpi} ({Source}), " +
            "paper={PaperShort}x{PaperLong}in, " +
            "margins L={ML}/R={MR}/T={MT}/B={MB} mm, scale={Scale}, orient={Orient}",
            fileName, sourceInfo.Width, sourceInfo.Height,
            originalSourceDpi, hasMetadataDpi ? "metadata" : "fallback-96",
            paperShortInches, paperLongInches,
            margins.LeftMm, margins.RightMm, margins.TopMm, margins.BottomMm,
            scale, orientation);

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
        logger.LogInformation(
            "preprocess {File}: classifier auto={Auto} (colours={Colours}, edges={Edges:P1}), " +
            "user-choice={Choice} => effective={Effective}",
            fileName, autoClass, classStats.UniqueQuantisedColours,
            classStats.EdgeDensity, upscalerChoice, effectiveClass);

        // Source bytes that'll be Lanczos3'd to the final 600 dpi
        // target. For Graphics: run Real-ESRGAN ×4, and if the result
        // is still well short of the engine target, run a second
        // pass to overshoot — Lanczos-DOWN from a slight overshoot
        // is sharper than Lanczos-UP from a shortfall. For Photo:
        // skip neural, Lanczos3 directly from source.
        byte[] workingBytes = sourceBytes;
        UpscalerUsed upscalerUsed = UpscalerUsed.Lanczos3;
        if (effectiveClass == ContentClass.Graphics && neuralUpscaler is not null)
        {
            // Target long-axis pixel count we want to overshoot.
            // We compare against canvas (paper × 600), not printable
            // — the canvas is what the Lanczos finish will resize to,
            // and Fit-mode shrinks within that.
            var targetLongPx = (int)Math.Round(
                Math.Max(paperShortInches, paperLongInches) * TargetDpi);

            // Predict how many neural passes will fire so we can
            // pre-compute progress weights. The loop's gate is
            //   ratio = targetLongPx / currentLong  ≥ 1.5
            // for pass N>0 (pass 0 always runs). Walk that gate once
            // up front rather than discovering pass count mid-stream.
            int expectedPasses = 1;
            {
                var initialLong = Math.Max(sourceInfo.Width, sourceInfo.Height);
                if ((double)targetLongPx / (initialLong * 4) >= 1.5)
                    expectedPasses = 2;
            }
            // Surface-area weights: pass N produces 16^N pixels per
            // source pixel (×4 each side). Compute time scales roughly
            // with output area (measured: pass 0 ≈ 30 s, pass 1 ≈
            // 370 s on Pi 5 llvmpipe; ratio ≈ 12 ×, close to the 16 ×
            // surface-area weighting). Allocate the bar accordingly.
            double[] passWeights = new double[expectedPasses];
            double cumWeight = 0;
            for (int i = 0; i < expectedPasses; i++)
            {
                passWeights[i] = System.Math.Pow(16, i + 1);
                cumWeight += passWeights[i];
            }
            double totalWeight = cumWeight;
            double completedWeight = 0;

            // Multi-pass loop. State tracked between passes:
            //   currentBytes   — the latest neural output (PNG with
            //                    correctly-stamped pHYs).
            //   currentLong    — long-axis pixel count after the most
            //                    recent pass.
            //   currentDpi     — the latest stamped DPI; threaded to
            //                    the next pass so RendererClient
            //                    stamps the NEXT result correctly.
            //   appliedScale   — cumulative neural scale factor
            //                    (4, 16, … capped at 16 = 2 passes
            //                    of ×4). Logged at the end so
            //                    operators can see what ran.
            //
            // Cap at 2 passes total. The realesr-animevideov3 model
            // is the same ×4 variant each pass — composing it twice
            // is what gives us up to ×16 linear when needed (e.g.
            // a 500-px screenshot → ×16 = 8000 px, well over the
            // 7016-px A4 long-axis target). Loops further would risk
            // amplifying neural artefacts; 2 passes is the sweet spot
            // for the screenshot/coloring-page class.
            // Source dims come from `sourceInfo` (identified before
            // the classifier ran) — we need them BEFORE the first
            // neural pass, while the (possibly upscaled) rgbImage
            // isn't opened until after the loop completes.
            var currentBytes = sourceBytes;
            var currentLong  = Math.Max(sourceInfo.Width, sourceInfo.Height);
            var currentDpi   = originalSourceDpi;
            var appliedScale = 1;

            logger.LogInformation(
                "preprocess {File}: neural-upscale starting, target long axis = {TargetLong} px " +
                "(canvas long = paper × {Dpi} dpi)",
                fileName, targetLongPx, TargetDpi);

            for (int pass = 0; pass < 2; pass++)
            {
                // Stop overshooting beyond ~1.1×: if we're already
                // ≥ 90 % of target on the long axis after the
                // previous pass, the Lanczos finish handles the
                // remaining gap. Specifically, we proceed only when
                // another ×4 would land us comfortably past target.
                var remainingRatio = (double)targetLongPx / currentLong;
                if (remainingRatio < 1.5 && pass > 0)
                {
                    logger.LogInformation(
                        "preprocess {File}: neural pass {Pass} skipped, " +
                        "remaining ratio {Ratio:F2} < 1.5 (already ≥ 66 % of target)",
                        fileName, pass, remainingRatio);
                    break;
                }
                // First pass always runs (we entered this branch
                // because the bot routed Graphics → neural); the
                // ratio check only gates the SECOND pass.

                logger.LogInformation(
                    "preprocess {File}: neural pass {Pass} start, " +
                    "input long={InLong} dpi={InDpi}, scale=×4, remaining ratio={Ratio:F2}",
                    fileName, pass, currentLong, currentDpi, remainingRatio);
                var passSw = System.Diagnostics.Stopwatch.StartNew();
                // Map this pass's 0..100 inner percent onto the slice
                // of the global bar this pass owns. completed weight
                // already covers prior passes; this pass adds up to
                // passWeights[pass] units as it runs.
                double startPctForPass = completedWeight / totalWeight * 100.0;
                double passSpanPct = passWeights[pass] / totalWeight * 100.0;
                int lastReportedGlobal = -1;
                var passProgress = new Progress<double>(innerPct =>
                {
                    var global = startPctForPass + (innerPct / 100.0) * passSpanPct;
                    var globalI = (int)System.Math.Floor(global);
                    if (globalI != lastReportedGlobal)
                    {
                        lastReportedGlobal = globalI;
                        onProgress?.Invoke(
                            globalI,
                            expectedPasses > 1
                                ? $"neural pass {pass + 1} of {expectedPasses} · {innerPct:F0}%"
                                : $"neural · {innerPct:F0}%");
                    }
                });
                // Initial-state notification: bot wants to swap from
                // "Preparing" indeterminate to a real bar immediately
                // when the pass starts, even before realesrgan emits
                // its first percent line (≈3 s of model load latency).
                onProgress?.Invoke(
                    (int)System.Math.Floor(startPctForPass),
                    expectedPasses > 1
                        ? $"neural pass {pass + 1} of {expectedPasses} · 0%"
                        : "neural · 0%");
                var passBytes = await neuralUpscaler(
                    currentBytes, fileName, 4, currentDpi, passProgress, ct);
                passSw.Stop();
                completedWeight += passWeights[pass];
                if (passBytes is null)
                {
                    // Neural failed on this pass. If pass 0: signal
                    // fallback to caller, fall through to Lanczos3
                    // from source. If pass 1: keep what pass 0 gave
                    // us (already a valid Neural result).
                    logger.LogWarning(
                        "preprocess {File}: neural pass {Pass} FAILED after {Elapsed:F1}s; " +
                        "{Outcome}",
                        fileName, pass, passSw.Elapsed.TotalSeconds,
                        pass == 0
                            ? "falling back to Lanczos3 from source"
                            : "keeping pass-0 result, skipping further passes");
                    if (pass == 0)
                        upscalerUsed = UpscalerUsed.NeuralFailedFellBackToLanczos;
                    break;
                }
                currentBytes = passBytes;
                currentLong  *= 4;
                currentDpi   *= 4;
                appliedScale *= 4;
                upscalerUsed = UpscalerUsed.Neural;
                logger.LogInformation(
                    "preprocess {File}: neural pass {Pass} OK in {Elapsed:F1}s, " +
                    "now long={OutLong} dpi={OutDpi}, cumulative ×{Cum}",
                    fileName, pass, passSw.Elapsed.TotalSeconds,
                    currentLong, currentDpi, appliedScale);

                // Done if the next pass would clearly overshoot the
                // overshoot — pass 0 ratio check above handles
                // pass 1, this is the early-exit when ratio dropped
                // below the threshold during pass 0.
                if ((double)targetLongPx / currentLong < 1.5) break;
            }

            if (upscalerUsed == UpscalerUsed.Neural)
                workingBytes = currentBytes;
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
        // Same unit-aware read as above. After our RendererClient
        // pHYs stamp the working image's metadata is always in
        // PixelsPerInch (the stamp writes that explicitly), but be
        // defensive about Photo paths where we didn't restamp.
        var workingDpi = ImageMetaDpi.ReadMinDpi(rgbImage.Metadata)
            ?? originalSourceDpi;

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
        logger.LogInformation(
            "preprocess {File}: canvas={CW}x{CH} px (full paper), " +
            "printable={PW}x{PH} px (canvas minus margins L={ML}/R={MR}/T={MT}/B={MB} px), " +
            "effective orient={Orient}",
            fileName, canvasW, canvasH, printableW, printableH,
            marginLPx, marginRPx, marginTPx, marginBPx, effectiveOrient);

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
        logger.LogInformation(
            "preprocess {File}: scale-mode {Mode} → content rect {CW}x{CH} px " +
            "(from working {WW}x{WH} px @ {WD} dpi); Lanczos3 ratio H={Rh:F3} V={Rv:F3} " +
            "({Direction})",
            fileName, scale, contentW, contentH, srcW, srcH, workingDpi,
            (double)contentW / srcW, (double)contentH / srcH,
            (contentW >= srcW && contentH >= srcH) ? "up"
                : (contentW <= srcW && contentH <= srcH) ? "down" : "mixed");
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
        logger.LogInformation(
            "preprocess {File}: composited at ({Ox},{Oy}) into white {CW}x{CH} L8 canvas; " +
            "wrapping to PDF",
            fileName, offsetX, offsetY, canvasW, canvasH);
        canvas.Metadata.HorizontalResolution = TargetDpi;
        canvas.Metadata.VerticalResolution   = TargetDpi;
        canvas.Metadata.ResolutionUnits =
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerInch;

        // PrintPdfWrap now just wraps an already-engine-grid bitmap.
        // No cm-matrix scaling, no rotation, no clip — the bitmap
        // has all of that baked in.
        var pdfBytes = PrintPdfWrap.WrapImage(
            canvas, paperShortInches, paperLongInches);
        logger.LogInformation(
            "preprocess {File}: PDF wrap done, MediaBox={MW:F1}x{MH:F1} pt " +
            "({PaperShort}x{PaperLong} in), image XObject={CW}x{CH} px /Interpolate=false, " +
            "{Bytes} byte PDF; pipeline complete (upscaler={Upscaler}, finalDpi={Dpi})",
            fileName, paperShortInches * 72.0, paperLongInches * 72.0,
            paperShortInches, paperLongInches, canvasW, canvasH,
            pdfBytes.Length, upscalerUsed, TargetDpi);

        return new Result(pdfBytes, canvasW, canvasH, TargetDpi,
            contentClass, classStats, upscalerUsed);
    }
}
