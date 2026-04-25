using System.Diagnostics;
using PrintScan.Renderer;

// PrintScan.Renderer — small, dedicated daemon whose only job is to
// take a user-supplied document (.doc / .docx / .odt / .rtf / .txt /
// …) and convert it to PDF via headless LibreOffice.
//
// Why a separate process from PrintScan.Daemon: parsing untrusted
// office documents is a substantial attack surface (UNO bridge, font
// engines, embedded scripting, OLE objects, malformed XML in zips).
// We treat each render request as a hostile input and want
// containment if libreoffice or one of its parsers blows up. The
// systemd unit (see ../default.nix) wraps this whole process in a
// "no-network, no-home, no-devices, dropped-caps, private-tmp"
// jail, and each render runs a fresh `soffice` *child* — a crash
// in libreoffice's parsing path takes the child down, the parent
// daemon catches the non-zero exit, returns 502 to the caller, and
// stays running for the next request.
//
// Wire shape: HTTP-over-unix-socket, mirroring the print/scan
// daemon's pattern. POST /render with a multipart `file` field;
// success → 200 + application/pdf body; failure → 4xx/5xx + text
// error. Synchronous: caller blocks ~5–10 s on Pi-class hardware
// while soffice cold-starts and converts.

if (Environment.GetEnvironmentVariable("LISTEN_FDS") is null)
    throw new InvalidOperationException(
        "PrintScan.Renderer requires systemd socket activation (LISTEN_FDS unset). "
      + "Start via `systemctl start printscan-renderer.socket`.");

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseSystemd();

// Kestrel binds the systemd-passed fd 3 (the socket created by the
// .socket unit). We never serve TCP — fail fast if fd 3 isn't there.
builder.WebHost.ConfigureKestrel(opts =>
{
    var lifetime = new System.Net.Sockets.Socket(
        new System.Net.Sockets.SafeSocketHandle(
            new IntPtr(3), ownsHandle: true));
    opts.ListenHandle((ulong)lifetime.Handle.ToInt64());
});

var app = builder.Build();
var log = app.Services.GetRequiredService<ILogger<Program>>();
log.LogInformation("PrintScan.Renderer starting (soffice={Path})",
    ToolPaths.Soffice);

app.MapGet("/health", () => Results.Ok(new { ok = true }));

app.MapPost("/render", async (HttpRequest request, CancellationToken ct) =>
{
    var form = await request.ReadFormAsync(ct);
    var file = form.Files.FirstOrDefault();
    if (file is null) return Results.BadRequest("No file provided");
    if (file.Length <= 0) return Results.BadRequest("Empty file");

    var jobId = Guid.NewGuid().ToString("N")[..12];
    // Per-job scratch directory under the systemd-managed StateDirectory.
    // Holds the input copy, soffice's UserInstallation profile, and the
    // PDF output. Nuked at the end regardless of success/failure.
    var stateRoot = Environment.GetEnvironmentVariable("STATE_DIRECTORY")
        ?? "/var/lib/printscan-renderer";
    var jobDir = Path.Combine(stateRoot, "jobs", jobId);
    Directory.CreateDirectory(jobDir);
    log.LogInformation("render {Job}: {File} ({Bytes} bytes)",
        jobId, file.FileName, file.Length);

    try
    {
        // Copy the upload to disk — soffice insists on a real file path,
        // it can't read the input stream directly. Sanitise the name
        // in case it carries shell metacharacters or path components.
        var safeName = MakeSafeFilename(file.FileName ?? "input");
        var inputPath = Path.Combine(jobDir, safeName);
        await using (var fs = File.Create(inputPath))
            await file.CopyToAsync(fs, ct);

        // soffice's UserInstallation lock is the single biggest source
        // of "second invocation hangs forever" bugs — the default
        // ~/.config/libreoffice/4 is shared across PIDs and has a
        // process-lock file. Give each invocation its own profile dir
        // inside the per-job scratch so concurrent renders don't fight.
        var profileDir = Path.Combine(jobDir, "profile");
        Directory.CreateDirectory(profileDir);

        var psi = new ProcessStartInfo(ToolPaths.Soffice)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            WorkingDirectory = jobDir,
        };
        psi.ArgumentList.Add($"-env:UserInstallation=file://{profileDir}");
        psi.ArgumentList.Add("--headless");
        psi.ArgumentList.Add("--norestore");
        psi.ArgumentList.Add("--nolockcheck");
        psi.ArgumentList.Add("--nologo");
        psi.ArgumentList.Add("--nodefault");
        psi.ArgumentList.Add("--convert-to");
        psi.ArgumentList.Add("pdf");
        psi.ArgumentList.Add("--outdir");
        psi.ArgumentList.Add(jobDir);
        psi.ArgumentList.Add(inputPath);

        var sw = Stopwatch.StartNew();
        using var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to spawn soffice");

        // 2-minute hard cap — soffice on a Pi 4 is comfortably under
        // 30 s for a typical .docx; anything past 2 minutes is a stuck
        // child that we'd rather kill and report failure on than hang
        // the whole bot UX.
        using var killCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        killCts.CancelAfter(TimeSpan.FromMinutes(2));
        var stdoutTask = proc.StandardOutput.ReadToEndAsync(killCts.Token);
        var stderrTask = proc.StandardError.ReadToEndAsync(killCts.Token);
        try { await proc.WaitForExitAsync(killCts.Token); }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            log.LogWarning("render {Job}: timed out after 2 min, killed", jobId);
            return Results.StatusCode(StatusCodes.Status504GatewayTimeout);
        }
        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        sw.Stop();
        log.LogInformation("render {Job}: soffice exit={Code} in {Elapsed:F1}s",
            jobId, proc.ExitCode, sw.Elapsed.TotalSeconds);

        if (proc.ExitCode != 0)
        {
            log.LogWarning("render {Job}: soffice failed: {Err}",
                jobId, stderr.Trim());
            return Results.Problem(
                detail: $"libreoffice exited {proc.ExitCode}: {Trunc(stderr)}",
                statusCode: 502);
        }

        // soffice writes <input-basename>.pdf alongside the input.
        var baseName = Path.GetFileNameWithoutExtension(inputPath);
        var outputPath = Path.Combine(jobDir, baseName + ".pdf");
        if (!File.Exists(outputPath))
        {
            log.LogWarning("render {Job}: soffice exited 0 but no PDF at {Path}. " +
                "stdout={Out} stderr={Err}",
                jobId, outputPath, Trunc(stdout), Trunc(stderr));
            return Results.Problem(
                detail: "libreoffice produced no PDF",
                statusCode: 502);
        }

        var pdfBytes = await File.ReadAllBytesAsync(outputPath, ct);
        log.LogInformation("render {Job}: produced {Bytes} byte PDF",
            jobId, pdfBytes.Length);
        return Results.File(pdfBytes,
            contentType: "application/pdf",
            fileDownloadName: baseName + ".pdf");
    }
    catch (Exception ex)
    {
        log.LogError(ex, "render {Job} failed", jobId);
        return Results.Problem(detail: ex.Message, statusCode: 500);
    }
    finally
    {
        // Wipe scratch — even on success, since the PDF is already in
        // the response body and we don't need it any more.
        try { Directory.Delete(jobDir, recursive: true); }
        catch (Exception ex) { log.LogDebug("scratch cleanup: {Err}", ex.Message); }
    }
});

await app.RunAsync();

static string MakeSafeFilename(string name)
{
    // Drop any path components and any character that isn't ASCII
    // alnum/dash/underscore/dot. Belt-and-braces — we run inside a
    // namespaced systemd jail with ProtectSystem=strict, so a
    // traversal would fail at fs level anyway, but this also
    // makes the soffice command line clean.
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
