using System.Diagnostics;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Shells out to <c>lp</c> for printing and <c>lpstat</c> for status.
/// Unchanged from the original daemon — the session refactor is scan-only.
/// </summary>
public sealed class PrintService
{
    private readonly ILogger<PrintService> _logger;
    public PrintService(ILogger<PrintService> logger) { _logger = logger; }

    public PrinterStatus GetStatus()
    {
        try
        {
            var result = RunCommand(ToolPaths.LpStat, "-p");
            var online = result.ExitCode == 0 && !result.Output.Contains("disabled");
            return new PrinterStatus(online, result.Output.Trim());
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to get printer status");
            return new PrinterStatus(false, ex.Message);
        }
    }

    public async Task<bool> PrintAsync(PrintRequest request, CancellationToken ct)
    {
        var tempFile = Path.Combine(Path.GetTempPath(),
            $"printscan-{Guid.NewGuid()}{Path.GetExtension(request.FileName)}");
        try
        {
            await File.WriteAllBytesAsync(tempFile, request.FileData, ct);
            var args = new List<string> { tempFile };
            if (request.Copies > 1) args.AddRange(["-n", request.Copies.ToString()]);
            if (!string.IsNullOrEmpty(request.PageRange))
                args.AddRange(["-o", $"page-ranges={request.PageRange}"]);
            var result = RunCommand(ToolPaths.Lp, string.Join(" ", args));
            if (result.ExitCode != 0)
            {
                _logger.LogError("lp failed: {Error}", result.Error);
                return false;
            }
            _logger.LogInformation("Printed {File} ({Copies} copies, pages: {Pages})",
                request.FileName, request.Copies, request.PageRange ?? "all");
            return true;
        }
        finally
        {
            try { File.Delete(tempFile); } catch { }
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

    private record CommandResult(int ExitCode, string Output, string Error);
}
