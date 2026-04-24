using System.Diagnostics;
using Microsoft.IO;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Runs a single <c>scanimage</c> invocation, piping its stdout into a
/// <see cref="RecyclableMemoryStream"/> (chunked pool-backed — no LOH, no
/// tempfiles, swap-friendly under memory pressure).
/// </summary>
public sealed class ScanPipeline
{
    private static readonly RecyclableMemoryStreamManager Pool = new(
        new RecyclableMemoryStreamManager.Options
        {
            BlockSize = 128 * 1024,          // 128 KB blocks
            LargeBufferMultiple = 1024 * 1024, // 1 MB large-buffer step
            MaximumBufferSize = 16 * 1024 * 1024, // 16 MB cap per block
            GenerateCallStacks = false,
            AggressiveBufferReturn = true
        });

    private readonly ILogger<ScanPipeline> _logger;

    public ScanPipeline(ILogger<ScanPipeline> logger) { _logger = logger; }

    public record Result(RecyclableMemoryStream Data, string ContentType, string FileExtension);

    /// <summary>
    /// Scan synchronously into a fresh RecyclableMemoryStream. Caller owns the
    /// stream and must dispose it. Throws on non-zero exit or spawn failure.
    /// </summary>
    public async Task<Result> ScanAsync(ScanParams p, CancellationToken ct)
    {
        var formatArg = p.Format switch
        {
            ScanFormat.Png => "png",
            ScanFormat.Tiff => "tiff",
            _ => "jpeg",
        };
        var (contentType, ext) = p.Format switch
        {
            ScanFormat.Png => ("image/png", "png"),
            ScanFormat.Tiff => ("image/tiff", "tiff"),
            _ => ("image/jpeg", "jpg"),
        };

        var args = $"--resolution {p.Dpi} --format {formatArg}";
        // NOTE: sane-backends 1.4.0's scanimage rejects --jpeg-quality as
        // an unrecognized option (it's a backend-specific option and our
        // epkowa backend doesn't expose it). Accept scanimage's built-in
        // default JPEG quality (~75) for now. If we ever need finer
        // control, pipe the PNM/TIFF output through cjpeg or ImageMagick
        // rather than relying on scanimage's --jpeg-quality path.
        // p.JpegQuality is kept in the config model for future use.
        // --output-file omitted → scanimage writes to stdout
        _logger.LogInformation("scanimage {Args}", args);

        var psi = new ProcessStartInfo(ToolPaths.ScanImage, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        using var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start scanimage");

        var memStream = Pool.GetStream("scan");
        var copyTask = proc.StandardOutput.BaseStream.CopyToAsync(memStream, ct);
        var stderrTask = proc.StandardError.ReadToEndAsync(ct);

        await copyTask;
        await proc.WaitForExitAsync(ct);
        var stderr = await stderrTask;

        if (proc.ExitCode != 0)
        {
            memStream.Dispose();
            throw new InvalidOperationException(
                $"scanimage exited {proc.ExitCode}: {stderr.Trim()}");
        }

        memStream.Position = 0;
        _logger.LogInformation("scan complete: {Bytes} bytes {Ext}", memStream.Length, ext);
        return new Result(memStream, contentType, ext);
    }
}
