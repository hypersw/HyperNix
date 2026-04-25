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

builder.WebHost.ConfigureKestrel(opts =>
{
    var sock = new System.Net.Sockets.Socket(
        new System.Net.Sockets.SafeSocketHandle(
            new IntPtr(3), ownsHandle: true));
    opts.ListenHandle((ulong)sock.Handle.ToInt64());
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
    string inputPath, string jobDir, ILogger log, string jobId, CancellationToken ct)
{
    var docxPath = Path.Combine(jobDir,
        Path.GetFileNameWithoutExtension(inputPath) + ".docx");
    // Markdown → DOCX. --standalone for a complete document,
    // --mathml not used here since the docx writer emits OMML
    // natively for inline LaTeX math (`$x^2$`) and display math
    // blocks (`$$ … $$`).
    await RunToolAsync(
        ToolPaths.Pandoc,
        ["--from=markdown", "--to=docx", "--standalone",
         "--output=" + docxPath, inputPath],
        jobDir, jobId, "pandoc", log, ct, TimeSpan.FromMinutes(1));
    if (!File.Exists(docxPath))
        throw new RenderFailedException("pandoc",
            "markdown → docx produced no output",
            "pandoc reported success but no output at " + docxPath);
    // Then docx → PDF via the regular soffice path.
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
    ILogger log, CancellationToken ct, TimeSpan timeout)
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
    var stdoutTask = proc.StandardOutput.ReadToEndAsync(killCts.Token);
    var stderrTask = proc.StandardError.ReadToEndAsync(killCts.Token);
    try { await proc.WaitForExitAsync(killCts.Token); }
    catch (OperationCanceledException)
    {
        try { proc.Kill(entireProcessTree: true); } catch { }
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
