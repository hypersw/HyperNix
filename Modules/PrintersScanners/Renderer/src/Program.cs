using System.Diagnostics;
using PrintScan.Renderer;

// PrintScan.Renderer — small, dedicated daemon whose only job is to
// take a user-supplied document (PDF, DOC/DOCX/ODT, Markdown,
// HTML, XPS/OXPS, plain text, …) and turn it into a uniform PDF
// the print pipeline can consume. Also reports basic metadata
// (page count) on existing PDFs to support the bot's per-page
// checkbox UI.
//
// Why a separate process from PrintScan.Daemon: parsing untrusted
// office documents is a substantial attack surface (UNO bridge,
// font engines, embedded scripting, OLE objects, malformed XML in
// zips). The systemd unit (see ../default.nix) wraps this whole
// process in a "no-network, no-home, no-devices, dropped-caps,
// private-tmp" jail, and each render runs a fresh subprocess —
// a crash takes the child down, the parent daemon catches the
// non-zero exit, returns 502 to the caller, and stays running
// for the next request.
//
// Wire shape: HTTP-over-unix-socket. Synchronous endpoints; the
// caller blocks while soffice/pandoc/xpstopdf does its work.
//
//   POST /render    — multipart `file`. Returns 200 + application/pdf,
//                     or 4xx/5xx + text/plain stderr on failure.
//   POST /pdf-info  — multipart `file` (must be a PDF). Returns
//                     application/json {"pageCount": N} or 4xx.
//   GET  /health    — liveness probe.

if (Environment.GetEnvironmentVariable("LISTEN_FDS") is null)
    throw new InvalidOperationException(
        "PrintScan.Renderer requires systemd socket activation (LISTEN_FDS unset). "
      + "Start via `systemctl start printscan-renderer.socket`.");

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseSystemd();

// systemd-activated socket comes in on fd 3 (LISTEN_FDS protocol).
// Hand it straight to Kestrel — ListenHandle wraps the raw handle
// itself.
//
// Past bug, this was written as:
//
//   builder.WebHost.ConfigureKestrel(opts => {
//     var sock = new Socket(new SafeSocketHandle((IntPtr)3,
//                                                ownsHandle: true));
//     opts.ListenHandle((ulong)sock.Handle.ToInt64());
//   });
//
// — creating an intermediate Socket #1 with `ownsHandle: true`,
// then passing its handle value to ListenHandle (which internally
// wraps the same fd 3 in Socket #2). Net result: two Socket objects
// both implicitly owning fd 3.
//
// The lambda returns, `sock` is GC-collectible. As soon as GC
// finalizes it (~one request worth of allocation pressure later),
// its finalizer runs and closes fd 3. Linux then reuses fd 3 for
// the next file-open in the renderer (job dir cleanup, log flush,
// anything). Kestrel's still-live Socket #2 calls accept() on what
// it thinks is its listener but is now a regular file → ENOTSOCK
// → exception storm. Symptom: works exactly once, then the accept
// loop pins a core in StackTrace.ToString allocations.
builder.WebHost.ConfigureKestrel(opts => opts.ListenHandle((ulong)3));

// Graceful-shutdown window: how long the host keeps Kestrel alive
// after SIGTERM, letting in-flight requests finish naturally before
// RequestAborted fires on them. Default is 30 s — fine for soffice /
// pandoc work but way short for /image-upscale, which on Pi 5 CPU
// Vulkan takes ~30 s (pass 0) to ~6 min (pass 1). Without this bump,
// an auto-rebuild that restarts the renderer mid-upscale will abort
// the bot's HTTP call after 30 s, which kills the realesrgan child
// and orphans the bot's TG status message at whatever progress it
// last rendered. Match the unit's TimeoutStopSec (defined in
// default.nix) with 1 min slack for the SSE final-event write + the
// host's post-Kestrel cleanup.
builder.Services.Configure<Microsoft.Extensions.Hosting.HostOptions>(opts =>
{
    opts.ShutdownTimeout = System.TimeSpan.FromMinutes(14);
});

var app = builder.Build();
var log = app.Services.GetRequiredService<ILogger<Program>>();
log.LogInformation(
    "PrintScan.Renderer starting (soffice={Soffice}, pandoc={Pandoc}, " +
    "xpstopdf={Xps}, pdfinfo={Info})",
    ToolPaths.Soffice, ToolPaths.Pandoc, ToolPaths.XpsToPdf, ToolPaths.PdfInfo);

app.MapGet("/health", () => Results.Ok(new { ok = true }));

app.MapPost("/render", async (HttpRequest request, CancellationToken ct) =>
{
    var form = await request.ReadFormAsync(ct);
    var file = form.Files.FirstOrDefault();
    if (file is null) return Results.BadRequest("No file provided");
    if (file.Length <= 0) return Results.BadRequest("Empty file");

    var jobId = Guid.NewGuid().ToString("N")[..12];
    var stateRoot = Environment.GetEnvironmentVariable("STATE_DIRECTORY")
        ?? "/var/lib/printscan-renderer";
    var jobDir = Path.Combine(stateRoot, "jobs", jobId);
    Directory.CreateDirectory(jobDir);
    log.LogInformation("render {Job}: {File} ({Bytes} bytes, type={Type})",
        jobId, file.FileName, file.Length, file.ContentType ?? "?");

    try
    {
        var safeName = MakeSafeFilename(file.FileName ?? "input");
        var inputPath = Path.Combine(jobDir, safeName);
        await using (var fs = File.Create(inputPath))
            await file.CopyToAsync(fs, ct);

        // Already a PDF? Just hand it back. Saves a soffice round-trip
        // when the bot is using /render as a "pass-through if it's
        // already PDF, convert otherwise" abstraction.
        var ext = Path.GetExtension(safeName).ToLowerInvariant();
        if (ext == ".pdf")
        {
            var bytes = await File.ReadAllBytesAsync(inputPath, ct);
            return Results.File(bytes, contentType: "application/pdf",
                fileDownloadName: Path.GetFileName(inputPath));
        }

        var outputPdf = await ConvertAsync(inputPath, jobDir, ext, log, jobId, ct);
        if (outputPdf is null)
            return Results.Problem(
                detail: "renderer produced no PDF — see daemon log",
                statusCode: 502);
        return Results.File(outputPdf, contentType: "application/pdf",
            fileDownloadName: Path.GetFileNameWithoutExtension(safeName) + ".pdf");
    }
    catch (RenderFailedException ex)
    {
        log.LogWarning("render {Job}: {Tool} failed: {Err}",
            jobId, ex.Tool, Trunc(ex.Details));
        // 502 = "upstream tool said no". Body carries a short
        // human-readable summary AND the raw stderr so the bot can
        // surface the latter under an expander rather than guessing
        // at what went wrong.
        return Results.Problem(
            title: ex.Friendly,
            detail: ex.Details,
            statusCode: 502);
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested)
    {
        return Results.StatusCode(StatusCodes.Status499ClientClosedRequest);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "render {Job} failed", jobId);
        return Results.Problem(
            title: "renderer crashed",
            detail: ex.Message,
            statusCode: 500);
    }
    finally
    {
        try { Directory.Delete(jobDir, recursive: true); }
        catch (Exception ex) { log.LogDebug("scratch cleanup: {Err}", ex.Message); }
    }
});

// Decode device-specific image containers (HEIC from iPhones, AVIF
// from modern web pipelines) into a vanilla PNG the bot's image
// path can then read with SixLabors.ImageSharp. Each tool runs in
// its own subprocess inside the renderer's existing systemd jail,
// so a CVE in libheif's HEVC decoder takes the child down rather
// than the parent.
app.MapPost("/image-convert", async (HttpRequest request, CancellationToken ct) =>
{
    var form = await request.ReadFormAsync(ct);
    var file = form.Files.FirstOrDefault();
    if (file is null) return Results.BadRequest("No file provided");
    if (file.Length <= 0) return Results.BadRequest("Empty file");

    var jobId = Guid.NewGuid().ToString("N")[..12];
    var stateRoot = Environment.GetEnvironmentVariable("STATE_DIRECTORY")
        ?? "/var/lib/printscan-renderer";
    var jobDir = Path.Combine(stateRoot, "jobs", jobId);
    Directory.CreateDirectory(jobDir);
    log.LogInformation("image-convert {Job}: {File} ({Bytes} bytes, type={Type})",
        jobId, file.FileName, file.Length, file.ContentType ?? "?");

    try
    {
        var safeName = MakeSafeFilename(file.FileName ?? "input");
        var inputPath = Path.Combine(jobDir, safeName);
        await using (var fs = File.Create(inputPath))
            await file.CopyToAsync(fs, ct);

        var ext = Path.GetExtension(safeName).ToLowerInvariant();
        var outputPath = Path.Combine(jobDir,
            Path.GetFileNameWithoutExtension(safeName) + ".png");

        // Try heif-convert first — it handles both HEIC and modern
        // AVIF, and libheif's build in nixpkgs typically includes
        // the AV1 decoders needed for the latter. Fall back to
        // avifdec on AVIF-specific failures.
        try
        {
            await RunToolAsync(
                ToolPaths.HeifConvert, [inputPath, outputPath],
                jobDir, jobId, "heif-convert", log, ct, TimeSpan.FromMinutes(1));
        }
        catch (RenderFailedException) when (ext is ".avif")
        {
            log.LogInformation(
                "image-convert {Job}: heif-convert failed on AVIF, retrying with avifdec",
                jobId);
            await RunToolAsync(
                ToolPaths.AvifDec, [inputPath, outputPath],
                jobDir, jobId, "avifdec", log, ct, TimeSpan.FromMinutes(1));
        }

        if (!File.Exists(outputPath))
            throw new RenderFailedException("image-convert",
                "image conversion produced no output",
                "decoder reported success but no output at " + outputPath);

        var pngBytes = await File.ReadAllBytesAsync(outputPath, ct);
        return Results.File(pngBytes,
            contentType: "image/png",
            fileDownloadName: Path.GetFileNameWithoutExtension(safeName) + ".png");
    }
    catch (RenderFailedException ex)
    {
        log.LogWarning("image-convert {Job}: {Tool} failed: {Err}",
            jobId, ex.Tool, Trunc(ex.Details));
        return Results.Problem(
            title: ex.Friendly, detail: ex.Details, statusCode: 502);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "image-convert {Job} failed", jobId);
        return Results.Problem(
            title: "image converter crashed",
            detail: ex.Message, statusCode: 500);
    }
    finally
    {
        try { Directory.Delete(jobDir, recursive: true); } catch { }
    }
});

// Neural upscaler — Real-ESRGAN with the realesr-animevideov3 model
// for anime / line-art / chart / cartoon content. Bot routes to this
// when its content classifier flags input as "graphics"; output is
// a 2×/3×/4× PNG (one of three model variants, picked by `scale`).
//
// Hardware path: the binary is ncnn-vulkan-only — it calls
// vkCreateInstance unconditionally at process startup, BEFORE the
// `-g` flag is consulted, so there is no "Vulkan-less" execution
// path. "CPU mode" (`-g -1`) inside this binary just means "use
// the loader's first ICD without device-side compute", not "skip
// Vulkan init". A host with no ICDs at all fails in ~10 ms with
// `vkCreateInstance failed -9 / invalid gpu device`.
//
// Pi 5 deployment hits this directly: hardware.graphics.enable is
// off (stage-1 boot stall), so no ICDs are registered globally.
// The renderer service therefore wires VK_ICD_FILENAMES =
// {mesa}/share/vulkan/icd.d/lvp_icd.<arch>.json (Mesa's llvmpipe
// software Vulkan) at the systemd-unit env level. v3dv (the Pi 5's
// real V3D7 driver) was tested and fails to compile ncnn's compute
// shaders; details in PLAN.md "Neural upscale on the Pi 5 — Vulkan
// ICD investigation".
//
// Caller can override the path via `gpu` form field: "auto"
// (default — try GPU first, fall back to CPU mode within the
// available ICD), "gpu" (Vulkan device only, fail if not exposed),
// "cpu" (force CPU mode via `-g -1`). On llvmpipe both modes are
// CPU under the hood; the gpu/cpu distinction matters only on
// hosts with a hardware Vulkan device.
// Note: this endpoint returns text/event-stream rather than a one-shot
// PNG. Each line of realesrgan-ncnn-vulkan's stdout that matches "NN.NN%"
// becomes a `progress` SSE event; the final upscaled PNG goes out as a
// terminal `result` event with the bytes base64-encoded inline. The bot
// consumes this with a streaming HTTP client so it can paint a live
// progress bar in Telegram during the ~30 s pass-0 / ~6 min pass-1
// neural work on the Pi 5 (llvmpipe-software-Vulkan CPU path).
//
// We could split progress (SSE) from result (separate GET) to avoid
// base64 overhead, but base64 on a ~7 MB PNG is ~9.3 MB string — fits
// comfortably in HTTP/1.1 chunked body and JsonSerializer's UTF-8
// writer, and keeps the bot's failure paths simpler (one connection
// owns the whole lifecycle).
app.MapPost("/image-upscale", async (HttpContext ctx, CancellationToken ct) =>
{
    var request = ctx.Request;
    if (!request.HasFormContentType)
    {
        ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
        await ctx.Response.WriteAsync("No multipart form body", ct);
        return;
    }
    var form = await request.ReadFormAsync(ct);
    var file = form.Files.FirstOrDefault();
    if (file is null || file.Length <= 0)
    {
        ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
        await ctx.Response.WriteAsync("No file provided", ct);
        return;
    }

    var scaleStr = form["scale"].FirstOrDefault() ?? "4";
    if (!int.TryParse(scaleStr, out var scaleX) || scaleX < 2 || scaleX > 4)
        scaleX = 4;
    var modelName = form["model"].FirstOrDefault() ?? "realesr-animevideov3";
    var modelKey = modelName == "realesr-animevideov3"
        ? $"{modelName}-x{scaleX}"
        : modelName;
    var gpuPref = (form["gpu"].FirstOrDefault() ?? "auto").ToLowerInvariant();

    var jobId = Guid.NewGuid().ToString("N")[..12];
    var stateRoot = Environment.GetEnvironmentVariable("STATE_DIRECTORY")
        ?? "/var/lib/printscan-renderer";
    var jobDir = Path.Combine(stateRoot, "jobs", jobId);
    Directory.CreateDirectory(jobDir);
    log.LogInformation(
        "image-upscale {Job}: {File} ({Bytes} B), model={Model}, ×{Scale}, gpu={Gpu}",
        jobId, file.FileName, file.Length, modelKey, scaleX, gpuPref);

    // Set up the SSE response shape eagerly. Headers go out before any
    // tool runs so the bot can attach to the stream and render the
    // "Preparing… 0 %" state immediately.
    ctx.Response.StatusCode = StatusCodes.Status200OK;
    ctx.Response.ContentType = "text/event-stream";
    ctx.Response.Headers.CacheControl = "no-cache, no-transform";
    ctx.Response.Headers["X-Accel-Buffering"] = "no";
    await ctx.Response.Body.FlushAsync(ct);

    var sseJson = new System.Text.Json.JsonSerializerOptions
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    async Task EmitAsync(object payload)
    {
        var json = System.Text.Json.JsonSerializer.Serialize(payload, sseJson);
        var frame = "data: " + json + "\n\n";
        await ctx.Response.WriteAsync(frame, ct);
        await ctx.Response.Body.FlushAsync(ct);
    }

    // Throttle progress events: realesrgan emits ~120 lines per pass on
    // Pi 5 (one per ≈0.25 s); we don't want to flood the bot. Drop any
    // line whose floor(pct) didn't move from the previous emit. Final
    // line (>= 100) always emits.
    var lastPctEmitted = -1;
    Func<string, Task> onLine = async (line) =>
    {
        line = line.Trim();
        if (line.Length < 2 || line[^1] != '%') return;
        var numeric = line[..^1];
        if (!double.TryParse(numeric,
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture,
                out var pct))
            return;
        var floored = (int)System.Math.Floor(pct);
        if (floored == lastPctEmitted && pct < 100) return;
        lastPctEmitted = floored;
        await EmitAsync(new { type = "progress", percent = pct });
    };

    try
    {
        var inputPath = Path.Combine(jobDir, MakeSafeFilename(file.FileName ?? "input"));
        await using (var fs = File.Create(inputPath))
            await file.CopyToAsync(fs, ct);
        var outputPath = Path.Combine(jobDir, "out.png");

        async Task RunUpscale(bool useGpu)
        {
            var args = new List<string>
            {
                "-i", inputPath,
                "-o", outputPath,
                "-n", modelKey,
                "-s", scaleX.ToString(),
                "-m", ToolPaths.RealEsrganModels,
            };
            if (!useGpu) { args.Add("-g"); args.Add("-1"); }
            await RunToolAsync(
                ToolPaths.RealEsrgan, args,
                jobDir, jobId,
                useGpu ? "realesrgan-vulkan" : "realesrgan-cpu",
                log, ct, TimeSpan.FromMinutes(20),
                // Realesrgan writes percent lines to stderr, not
                // stdout — surprised me but matches the binary's
                // behaviour. Wire the callback on both streams to
                // be robust against future build changes.
                onStdoutLine: onLine,
                onStderrLine: onLine);
        }

        try
        {
            switch (gpuPref)
            {
                case "gpu":  await RunUpscale(useGpu: true);  break;
                case "cpu":  await RunUpscale(useGpu: false); break;
                default:
                    try { await RunUpscale(useGpu: true); }
                    catch (RenderFailedException ex)
                    {
                        log.LogWarning(
                            "image-upscale {Job}: Vulkan path failed ({Err}); " +
                            "falling back to CPU mode",
                            jobId, Trunc(ex.Details, 200));
                        if (File.Exists(outputPath)) File.Delete(outputPath);
                        await EmitAsync(new { type = "stage", stage = "cpu-fallback" });
                        lastPctEmitted = -1;
                        await RunUpscale(useGpu: false);
                    }
                    break;
            }
        }
        catch (RenderFailedException ex)
        {
            log.LogWarning(
                "image-upscale {Job}: {Tool} failed: {Err}",
                jobId, ex.Tool, Trunc(ex.Details));
            await EmitAsync(new
            {
                type = "error",
                title = ex.Friendly,
                detail = Trunc(ex.Details, 400),
            });
            return;
        }

        if (!File.Exists(outputPath))
        {
            await EmitAsync(new
            {
                type = "error",
                title = "neural upscaler produced no output",
                detail = "realesrgan exited 0 but no output PNG at " + outputPath,
            });
            return;
        }

        var bytes = await File.ReadAllBytesAsync(outputPath, ct);
        log.LogInformation(
            "image-upscale {Job}: produced {Bytes} byte PNG",
            jobId, bytes.Length);
        await EmitAsync(new
        {
            type = "result",
            bytes = System.Convert.ToBase64String(bytes),
        });
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested)
    {
        log.LogInformation("image-upscale {Job}: client cancelled mid-stream", jobId);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "image-upscale {Job} crashed", jobId);
        try { await EmitAsync(new { type = "error", title = "image-upscale crashed", detail = ex.Message }); }
        catch { }
    }
    finally
    {
        try { Directory.Delete(jobDir, recursive: true); } catch { }
    }
});

// Multi-page PDF preview as a single grayscale WebP. The bot uses
// this for Pageables: rasterize the first N pages, stack them
// vertically with a thin separator, ship as a Document so Telegram
// doesn't recompress. Single ImageMagick invocation under the hood
// — IM rasterizes the PDF (via Ghostscript), grayscales, stacks,
// encodes WebP; we don't need to coordinate pdftoppm + montage
// ourselves.
app.MapPost("/pdf-preview", async (HttpRequest request, CancellationToken ct) =>
{
    var form = await request.ReadFormAsync(ct);
    var file = form.Files.FirstOrDefault();
    if (file is null) return Results.BadRequest("No file provided");
    if (file.Length <= 0) return Results.BadRequest("Empty file");

    // maxPages and density both have query/form fallbacks. 3 pages
    // at 120 dpi keeps the WebP under ~150 KB for typical content.
    var maxPagesStr = form["maxPages"].FirstOrDefault() ?? "3";
    if (!int.TryParse(maxPagesStr, out var maxPages) || maxPages < 1)
        maxPages = 3;
    if (maxPages > 10) maxPages = 10;
    var densityStr = form["density"].FirstOrDefault() ?? "120";
    if (!int.TryParse(densityStr, out var density) || density < 50)
        density = 120;
    if (density > 300) density = 300;

    var jobId = Guid.NewGuid().ToString("N")[..12];
    var stateRoot = Environment.GetEnvironmentVariable("STATE_DIRECTORY")
        ?? "/var/lib/printscan-renderer";
    var jobDir = Path.Combine(stateRoot, "jobs", jobId);
    Directory.CreateDirectory(jobDir);
    log.LogInformation("pdf-preview {Job}: {File} maxPages={MaxPages} density={Density}",
        jobId, file.FileName, maxPages, density);
    try
    {
        var inputPath = Path.Combine(jobDir, MakeSafeFilename(file.FileName ?? "input.pdf"));
        await using (var fs = File.Create(inputPath))
            await file.CopyToAsync(fs, ct);

        var outputPath = Path.Combine(jobDir, "preview.webp");
        // ImageMagick page-range is "[start-end]" 0-indexed.
        // Density first means it controls input rasterization.
        // -append stacks vertically; -alpha remove + -background white
        // flatten any transparency (otherwise WebP encodes alpha
        // that doesn't help us). -colorspace gray + -type Grayscale
        // commits to grayscale before encode.
        await RunToolAsync(
            ToolPaths.Magick,
            ["-density", density.ToString(),
             $"{inputPath}[0-{Math.Max(0, maxPages - 1)}]",
             "-alpha", "remove",
             "-background", "white",
             "-colorspace", "gray",
             "-type", "Grayscale",
             "-quality", "80",
             "-append",
             outputPath],
            jobDir, jobId, "magick", log, ct, TimeSpan.FromMinutes(2));
        if (!File.Exists(outputPath))
            throw new RenderFailedException("magick",
                "PDF preview produced no output",
                "magick reported success but no output at " + outputPath);
        var bytes = await File.ReadAllBytesAsync(outputPath, ct);
        log.LogInformation("pdf-preview {Job}: produced {Bytes} byte WebP",
            jobId, bytes.Length);
        return Results.File(bytes, contentType: "image/webp",
            fileDownloadName: "preview.webp");
    }
    catch (RenderFailedException ex)
    {
        log.LogWarning("pdf-preview {Job}: {Tool} failed: {Err}",
            jobId, ex.Tool, Trunc(ex.Details));
        return Results.Problem(
            title: ex.Friendly, detail: ex.Details, statusCode: 502);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "pdf-preview {Job} failed", jobId);
        return Results.Problem(
            title: "pdf preview crashed",
            detail: ex.Message, statusCode: 500);
    }
    finally
    {
        try { Directory.Delete(jobDir, recursive: true); } catch { }
    }
});

app.MapPost("/pdf-info", async (HttpRequest request, CancellationToken ct) =>
{
    var form = await request.ReadFormAsync(ct);
    var file = form.Files.FirstOrDefault();
    if (file is null) return Results.BadRequest("No file provided");
    if (file.Length <= 0) return Results.BadRequest("Empty file");

    var jobId = Guid.NewGuid().ToString("N")[..12];
    var stateRoot = Environment.GetEnvironmentVariable("STATE_DIRECTORY")
        ?? "/var/lib/printscan-renderer";
    var jobDir = Path.Combine(stateRoot, "jobs", jobId);
    Directory.CreateDirectory(jobDir);
    try
    {
        var inputPath = Path.Combine(jobDir, MakeSafeFilename(file.FileName ?? "input.pdf"));
        await using (var fs = File.Create(inputPath))
            await file.CopyToAsync(fs, ct);
        var (pageCount, raw) = await PdfInfoAsync(inputPath, ct);
        return Results.Json(new { pageCount, raw });
    }
    catch (RenderFailedException ex)
    {
        return Results.Problem(
            title: ex.Friendly, detail: ex.Details, statusCode: 502);
    }
    catch (Exception ex)
    {
        log.LogWarning(ex, "pdf-info {Job} failed", jobId);
        return Results.Problem(
            title: "pdfinfo crashed", detail: ex.Message, statusCode: 500);
    }
    finally
    {
        try { Directory.Delete(jobDir, recursive: true); } catch { }
    }
});

await app.RunAsync();

// ── Conversion routing ──────────────────────────────────────────────────────

static async Task<byte[]?> ConvertAsync(
    string inputPath, string jobDir, string ext,
    ILogger log, string jobId, CancellationToken ct)
{
    // Routing: pick the best-suited tool per format. Many of these
    // formats are technically convertible by soffice too (it's the
    // most omnivorous import), but we use the tool that gives the
    // cleanest output where one exists.
    return ext switch
    {
        // Microsoft XPS / Open XPS — soffice can't read these.
        ".xps" or ".oxps" =>
            await XpsToPdfAsync(inputPath, jobDir, log, jobId, ct),

        // Markdown — pandoc to docx, then soffice docx→pdf. Two-step
        // because pandoc needs a PDF engine for direct PDF output and
        // the lightest of those (weasyprint, ConTeXt) still has
        // significant install cost; pandoc's docx target is built-in
        // and soffice already has to be in the closure for office
        // formats anyway. Math (LaTeX-style) survives the round-trip
        // via OMML in the docx.
        ".md" or ".markdown" =>
            await MarkdownToPdfAsync(inputPath, jobDir, log, jobId, ct),

        // EPUB — zipped HTML+CSS+assets. soffice's import is
        // unreliable; pandoc handles EPUB natively. Same docx →
        // soffice tail as Markdown.
        ".epub" =>
            await PandocToPdfAsync(inputPath, jobDir, "epub", log, jobId, ct),

        // Office formats (incl. plain text and HTML which soffice
        // imports natively) — the catch-all soffice path.
        _ => await SofficeToPdfAsync(inputPath, jobDir, log, jobId, ct),
    };
}

// ── Tool wrappers ───────────────────────────────────────────────────────────

static async Task<byte[]> XpsToPdfAsync(
    string inputPath, string jobDir, ILogger log, string jobId, CancellationToken ct)
{
    var outPath = Path.Combine(jobDir,
        Path.GetFileNameWithoutExtension(inputPath) + ".pdf");
    await RunToolAsync(
        ToolPaths.XpsToPdf, [inputPath, outPath],
        jobDir, jobId, "xpstopdf", log, ct, TimeSpan.FromMinutes(2));
    if (!File.Exists(outPath))
        throw new RenderFailedException("xpstopdf",
            "XPS conversion produced no PDF",
            "xpstopdf reported success but no output file at " + outPath);
    return await File.ReadAllBytesAsync(outPath, ct);
}

static async Task<byte[]> MarkdownToPdfAsync(
    string inputPath, string jobDir, ILogger log, string jobId, CancellationToken ct) =>
    await PandocToPdfAsync(inputPath, jobDir, "markdown", log, jobId, ct);

/// <summary>
/// Generic pandoc-to-soffice path. Pandoc converts the source
/// format to DOCX (its built-in writer, no PDF engine needed),
/// then soffice converts the DOCX to PDF. Works the same way
/// for any of pandoc's input formats — Markdown, EPUB, etc.
/// </summary>
static async Task<byte[]> PandocToPdfAsync(
    string inputPath, string jobDir, string fromFormat,
    ILogger log, string jobId, CancellationToken ct)
{
    var docxPath = Path.Combine(jobDir,
        Path.GetFileNameWithoutExtension(inputPath) + ".docx");
    await RunToolAsync(
        ToolPaths.Pandoc,
        [$"--from={fromFormat}", "--to=docx", "--standalone",
         "--output=" + docxPath, inputPath],
        jobDir, jobId, "pandoc", log, ct, TimeSpan.FromMinutes(1));
    if (!File.Exists(docxPath))
        throw new RenderFailedException("pandoc",
            $"{fromFormat} → docx produced no output",
            "pandoc reported success but no output at " + docxPath);
    return await SofficeToPdfAsync(docxPath, jobDir, log, jobId, ct);
}

static async Task<byte[]> SofficeToPdfAsync(
    string inputPath, string jobDir, ILogger log, string jobId, CancellationToken ct)
{
    // Per-job UserInstallation profile — without this, concurrent
    // soffice invocations fight over the shared profile lock and the
    // second one hangs waiting for the first to release it.
    var profileDir = Path.Combine(jobDir, "profile");
    Directory.CreateDirectory(profileDir);
    await RunToolAsync(
        ToolPaths.Soffice,
        [$"-env:UserInstallation=file://{profileDir}",
         "--headless", "--norestore", "--nolockcheck",
         "--nologo", "--nodefault",
         "--convert-to", "pdf",
         "--outdir", jobDir,
         inputPath],
        jobDir, jobId, "soffice", log, ct, TimeSpan.FromMinutes(2));
    var outPath = Path.Combine(jobDir,
        Path.GetFileNameWithoutExtension(inputPath) + ".pdf");
    if (!File.Exists(outPath))
        throw new RenderFailedException("soffice",
            "LibreOffice produced no PDF",
            "soffice reported success but no output at " + outPath);
    return await File.ReadAllBytesAsync(outPath, ct);
}

static async Task<(int pageCount, string raw)> PdfInfoAsync(
    string inputPath, CancellationToken ct)
{
    var psi = new ProcessStartInfo(ToolPaths.PdfInfo)
    {
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
    };
    psi.ArgumentList.Add(inputPath);
    using var proc = Process.Start(psi)
        ?? throw new RenderFailedException("pdfinfo",
            "couldn't start pdfinfo", "Process.Start returned null");
    using var killCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
    killCts.CancelAfter(TimeSpan.FromSeconds(20));
    var stdoutTask = proc.StandardOutput.ReadToEndAsync(killCts.Token);
    var stderrTask = proc.StandardError.ReadToEndAsync(killCts.Token);
    try { await proc.WaitForExitAsync(killCts.Token); }
    catch (OperationCanceledException)
    {
        try { proc.Kill(entireProcessTree: true); } catch { }
        throw new RenderFailedException("pdfinfo",
            "pdfinfo timed out", "exceeded 20s wall clock");
    }
    var stdout = await stdoutTask;
    var stderr = await stderrTask;
    if (proc.ExitCode != 0)
        throw new RenderFailedException("pdfinfo",
            "couldn't read PDF metadata",
            (stderr.Trim().Length == 0 ? stdout : stderr).Trim());
    // pdfinfo's "Pages:" line — anything that doesn't have one is a
    // PDF we can't trust to even count.
    foreach (var line in stdout.Split('\n'))
    {
        if (line.StartsWith("Pages:"))
        {
            if (int.TryParse(line["Pages:".Length..].Trim(), out var n))
                return (n, stdout);
        }
    }
    throw new RenderFailedException("pdfinfo",
        "PDF has no page count",
        "pdfinfo output didn't contain a 'Pages:' line:\n" + stdout);
}

// Generic subprocess runner with structured error reporting. Captures
// stdout+stderr, enforces a wall-clock timeout, and packages failure
// modes (non-zero exit / timeout / spawn-failure) as RenderFailedException
// so the HTTP layer can return both a friendly summary and the raw tool
// output to the bot.
static async Task RunToolAsync(
    string exe, IReadOnlyList<string> args,
    string workDir, string jobId, string toolName,
    ILogger log, CancellationToken ct, TimeSpan timeout,
    Func<string, Task>? onStdoutLine = null,
    Func<string, Task>? onStderrLine = null)
{
    var psi = new ProcessStartInfo(exe)
    {
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false,
        WorkingDirectory = workDir,
    };
    foreach (var a in args) psi.ArgumentList.Add(a);

    var sw = Stopwatch.StartNew();
    using var proc = Process.Start(psi)
        ?? throw new RenderFailedException(toolName,
            $"couldn't spawn {toolName}",
            $"Process.Start({exe}) returned null");

    using var killCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
    killCts.CancelAfter(timeout);

    // Reader strategy: when a per-line callback is wired in (used by
    // /image-upscale for SSE progress), stream line-by-line and invoke
    // the callback on each. Otherwise fall back to the bulk
    // ReadToEndAsync that buffers the whole output until exit — same
    // shape as before, no behaviour change for the rest of the
    // pipeline (soffice, pandoc, magick, …).
    Task<string> stdoutTask = onStdoutLine is not null
        ? ReadLinesAsync(proc.StandardOutput, onStdoutLine, killCts.Token)
        : proc.StandardOutput.ReadToEndAsync(killCts.Token);
    Task<string> stderrTask = onStderrLine is not null
        ? ReadLinesAsync(proc.StandardError, onStderrLine, killCts.Token)
        : proc.StandardError.ReadToEndAsync(killCts.Token);

    try { await proc.WaitForExitAsync(killCts.Token); }
    catch (OperationCanceledException)
    {
        try { proc.Kill(entireProcessTree: true); } catch { }
        if (ct.IsCancellationRequested)
            throw;  // caller-initiated cancel: let it propagate
        throw new RenderFailedException(toolName,
            $"{toolName} timed out after {timeout.TotalSeconds:F0}s",
            "Killed by parent. " +
            $"Wall-clock {sw.Elapsed.TotalSeconds:F1}s, no clean exit.");
    }
    var stdout = await stdoutTask;
    var stderr = await stderrTask;
    sw.Stop();
    log.LogInformation("render {Job}: {Tool} exit={Code} in {Elapsed:F1}s",
        jobId, toolName, proc.ExitCode, sw.Elapsed.TotalSeconds);

    if (proc.ExitCode != 0)
        throw new RenderFailedException(toolName,
            $"{toolName} exited with code {proc.ExitCode}",
            (stderr.Trim().Length == 0 ? stdout : stderr).Trim());
}

// ── Helpers ─────────────────────────────────────────────────────────────────

static string MakeSafeFilename(string name)
{
    // Strip path components and any character that isn't ASCII
    // alnum/dash/underscore/dot. Belt-and-braces — we run inside a
    // namespaced systemd jail with ProtectSystem=strict so a
    // traversal would fail at fs level anyway, but this also makes
    // the subprocess command lines clean and shell-safe.
    name = Path.GetFileName(name ?? "input");
    if (string.IsNullOrEmpty(name)) name = "input";
    var sb = new System.Text.StringBuilder(name.Length);
    foreach (var c in name)
        sb.Append(char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_');
    var result = sb.ToString();
    return string.IsNullOrEmpty(result) ? "input" : result;
}

static string Trunc(string s, int max = 800) =>
    s.Length <= max ? s : s[..max] + "…";

/// <summary>
/// Stream a process's stdout/stderr line by line, invoke a callback on
/// each, and ALSO accumulate the full output so the caller still gets
/// the same "complete captured output" that ReadToEndAsync would have
/// produced. Used by /image-upscale to push realesrgan's percent
/// lines out over SSE while keeping the bulk-captured output around
/// for the post-mortem log line and the RenderFailedException's
/// `details` field on a non-zero exit.
///
/// Realesrgan-ncnn-vulkan emits one line per percent step
/// ("0.00%\n8.33%\n16.67%\n...100.00%"), interleaved with one-time
/// banner lines (GPU enumeration, model load). Both go through the
/// same channel; the caller parses what it cares about.
/// </summary>
static async Task<string> ReadLinesAsync(
    System.IO.StreamReader reader,
    Func<string, Task> onLine,
    CancellationToken ct)
{
    var sb = new System.Text.StringBuilder();
    while (!ct.IsCancellationRequested)
    {
        string? line;
        try { line = await reader.ReadLineAsync(ct); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
        if (line is null) break;
        sb.Append(line).Append('\n');
        try { await onLine(line); }
        catch { /* a flaky callback must not break process draining */ }
    }
    return sb.ToString();
}

namespace PrintScan.Renderer
{
    /// <summary>
    /// Carries both a short human-readable summary and the raw
    /// tool output. The HTTP layer maps this onto a 502 problem
    /// response so the bot can show the friendly title to the user
    /// and the raw output under an expander for debugging.
    /// </summary>
    internal sealed class RenderFailedException : Exception
    {
        public string Tool { get; }
        public string Friendly { get; }
        public string Details { get; }
        public RenderFailedException(string tool, string friendly, string details)
            : base(friendly + ": " + details)
        {
            Tool = tool;
            Friendly = friendly;
            Details = details;
        }
    }
}
