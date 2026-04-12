using System.Diagnostics;
using PrintScan.Shared;

var builder = WebApplication.CreateBuilder(args);

// Listen on Unix socket — path from env or default.
// When socket-activated by systemd, the socket file already exists and is
// managed by systemd. When running standalone, Kestrel creates it.
// ASPNETCORE_URLS is set by the NixOS module to "http://unix:<path>".
// No manual socket management needed — Kestrel handles both cases.

builder.Services.AddSingleton<PrintService>();
builder.Services.AddSingleton<ScanService>();

var app = builder.Build();

// ── Status ──
app.MapGet("/status", (PrintService print, ScanService scan) =>
    Results.Ok(new DeviceStatus(print.GetStatus(), scan.GetStatus())));

// ── Print ──
app.MapPost("/print", async (HttpRequest request, PrintService print) =>
{
    var form = await request.ReadFormAsync();
    var file = form.Files.FirstOrDefault();
    if (file is null)
        return Results.BadRequest("No file provided");

    var pageRange = form["pageRange"].FirstOrDefault();
    var copies = int.TryParse(form["copies"].FirstOrDefault(), out var c) ? c : 1;

    using var ms = new MemoryStream();
    await file.CopyToAsync(ms);

    var req = new PrintRequest(file.FileName, ms.ToArray(), pageRange, copies);
    var result = await print.PrintAsync(req);
    return result ? Results.Ok("Printed") : Results.StatusCode(500);
});

// ── Scan ──
app.MapPost("/scan", async (ScanService scan, HttpRequest request) =>
{
    var form = await request.ReadFormAsync();
    var dpi = int.TryParse(form["dpi"].FirstOrDefault(), out var d) ? d : 200;
    var formatStr = form["format"].FirstOrDefault() ?? "jpeg";
    var format = Enum.TryParse<ScanFormat>(formatStr, ignoreCase: true, out var f) ? f : ScanFormat.Jpeg;
    var quality = int.TryParse(form["quality"].FirstOrDefault(), out var q) ? q : 90;

    var job = await scan.StartScanAsync(new ScanRequest(dpi, format, quality));
    return Results.Ok(job);
});

app.MapGet("/scan/{id}", (string id, ScanService scan) =>
{
    var job = scan.GetJob(id);
    if (job is null)
        return Results.NotFound();
    if (job.Status == ScanJobStatus.Done && job.ResultPath is not null)
    {
        var stream = File.OpenRead(job.ResultPath);
        var contentType = job.ResultPath.EndsWith(".png") ? "image/png"
            : job.ResultPath.EndsWith(".tiff") ? "image/tiff"
            : "image/jpeg";
        return Results.Stream(stream, contentType, Path.GetFileName(job.ResultPath));
    }
    return Results.Ok(job);
});

app.MapGet("/jobs", (ScanService scan) => Results.Ok(scan.GetRecentJobs()));

app.Logger.LogInformation("PrintScan daemon listening on {Urls}", Environment.GetEnvironmentVariable("ASPNETCORE_URLS") ?? "default");
app.Run();

// ── Print Service (shells out to lp) ──
public class PrintService(ILogger<PrintService> logger)
{
    public PrinterStatus GetStatus()
    {
        try
        {
            var result = RunCommand("lpstat", "-p");
            var online = result.ExitCode == 0 && !result.Output.Contains("disabled");
            return new PrinterStatus(online, result.Output.Trim());
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to get printer status");
            return new PrinterStatus(false, ex.Message);
        }
    }

    public async Task<bool> PrintAsync(PrintRequest request)
    {
        var tempFile = Path.Combine(Path.GetTempPath(), $"printscan-{Guid.NewGuid()}{Path.GetExtension(request.FileName)}");
        try
        {
            await File.WriteAllBytesAsync(tempFile, request.FileData);

            var args = new List<string> { tempFile };
            if (request.Copies > 1)
                args.AddRange(["-n", request.Copies.ToString()]);
            if (!string.IsNullOrEmpty(request.PageRange))
                args.AddRange(["-o", $"page-ranges={request.PageRange}"]);

            var result = RunCommand("lp", string.Join(" ", args));
            if (result.ExitCode != 0)
            {
                logger.LogError("lp failed: {Error}", result.Error);
                return false;
            }

            logger.LogInformation("Printed {File} ({Copies} copies, pages: {Pages})",
                request.FileName, request.Copies, request.PageRange ?? "all");
            return true;
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    private static CommandResult RunCommand(string command, string args)
    {
        using var process = Process.Start(new ProcessStartInfo(command, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        })!;
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        return new CommandResult(process.ExitCode, output, error);
    }
}

// ── Scan Service (shells out to scanimage) ──
public class ScanService(ILogger<ScanService> logger)
{
    private readonly Dictionary<string, ScanJob> _jobs = new();
    private readonly Lock _lock = new();

    public ScannerStatus GetStatus()
    {
        try
        {
            var result = RunCommand("scanimage", "-L");
            var online = result.ExitCode == 0 && result.Output.Contains("epkowa");
            return new ScannerStatus(online, result.Output.Trim());
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to get scanner status");
            return new ScannerStatus(false, ex.Message);
        }
    }

    public async Task<ScanJob> StartScanAsync(ScanRequest request)
    {
        var id = Guid.NewGuid().ToString("N")[..8];
        var ext = request.Format switch
        {
            ScanFormat.Png => ".png",
            ScanFormat.Tiff => ".tiff",
            _ => ".jpg",
        };
        var outputPath = Path.Combine(Path.GetTempPath(), $"scan-{id}{ext}");

        var job = new ScanJob(id, ScanJobStatus.Scanning);
        lock (_lock) { _jobs[id] = job; }

        _ = Task.Run(async () =>
        {
            try
            {
                var formatArg = request.Format switch
                {
                    ScanFormat.Png => "png",
                    ScanFormat.Tiff => "tiff",
                    _ => "jpeg",
                };

                var args = $"--resolution {request.Dpi} --format {formatArg} --output-file {outputPath}";

                logger.LogInformation("Starting scan: {Args}", args);
                var result = await RunCommandAsync("scanimage", args);

                if (result.ExitCode != 0)
                {
                    logger.LogError("scanimage failed: {Error}", result.Error);
                    lock (_lock) { _jobs[id] = job with { Status = ScanJobStatus.Failed, Error = result.Error }; }
                    return;
                }

                logger.LogInformation("Scan complete: {Path}", outputPath);
                lock (_lock) { _jobs[id] = job with { Status = ScanJobStatus.Done, ResultPath = outputPath }; }
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Scan failed");
                lock (_lock) { _jobs[id] = job with { Status = ScanJobStatus.Failed, Error = ex.Message }; }
            }
        });

        return job;
    }

    public ScanJob? GetJob(string id)
    {
        lock (_lock) { return _jobs.GetValueOrDefault(id); }
    }

    public IReadOnlyList<ScanJob> GetRecentJobs()
    {
        lock (_lock) { return _jobs.Values.OrderByDescending(j => j.Id).Take(20).ToList(); }
    }

    private static CommandResult RunCommand(string command, string args)
    {
        using var process = Process.Start(new ProcessStartInfo(command, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        })!;
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        return new CommandResult(process.ExitCode, output, error);
    }

    private static async Task<CommandResult> RunCommandAsync(string command, string args)
    {
        using var process = Process.Start(new ProcessStartInfo(command, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        })!;
        var output = await process.StandardOutput.ReadToEndAsync();
        var error = await process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return new CommandResult(process.ExitCode, output, error);
    }
}

public record CommandResult(int ExitCode, string Output, string Error);
