using System.Diagnostics;
using Microsoft.IO;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Drives <c>scanimage</c> at USB-limited speed and returns the raw
/// TIFF blob it produced. That's the daemon's whole imagery role —
/// format selection, re-encoding, thumbnail generation, all of it
/// belongs to the client (the Telegram bot). Keeping the daemon out
/// of the imagery business means no ImageSharp on the scan host, no
/// font lookup, no client-specific concerns like Telegram thumbnail
/// dimensions, and no piles of stream references resident across
/// multiple scans.
///
/// Why scanimage produces uncompressed TIFF and not e.g. JPEG: the
/// JPEG/PNG encoder on a Pi 4 A72 runs slower than the scanner's USB
/// throughput, which back-pressures the SANE backend, which causes
/// the scanner to pause the carriage mid-page. Uncompressed TIFF is
/// "header + raw pixel rows" — zero CPU at scanimage, USB-limited.
/// </summary>
public sealed class ScanPipeline
{
    private static readonly RecyclableMemoryStreamManager Pool = new(
        new RecyclableMemoryStreamManager.Options
        {
            BlockSize = 128 * 1024,
            LargeBufferMultiple = 1024 * 1024,
            MaximumBufferSize = 16 * 1024 * 1024,
            GenerateCallStacks = false,
            AggressiveBufferReturn = true,
        });

    private readonly ILogger<ScanPipeline> _logger;

    public ScanPipeline(ILogger<ScanPipeline> logger) { _logger = logger; }

    /// <summary>
    /// Runs scanimage to completion and returns the resulting TIFF
    /// stream (rewound for reading). Caller owns the stream and must
    /// dispose it. Throws on non-zero exit or spawn failure.
    /// <paramref name="progress"/> is reported 0..99 while bytes are
    /// flowing (estimated from expected A4-page size at this dpi —
    /// rough but close enough for a UI bar) and 100 on clean exit.
    /// </summary>
    public async Task<RecyclableMemoryStream> ScanAsync(
        ScanParams p, IProgress<int>? progress, CancellationToken ct)
    {
        var total = Stopwatch.StartNew();
        var proc0 = Process.GetCurrentProcess();
        long MemRss() { proc0.Refresh(); return proc0.WorkingSet64; }
        long MemManaged() => GC.GetTotalMemory(false);
        string Fmt(long bytes) => $"{bytes / 1024.0 / 1024.0:F1} MB";
        _logger.LogInformation(
            "scan start: dpi={Dpi} rss={Rss} heap={Heap}",
            p.Dpi, Fmt(MemRss()), Fmt(MemManaged()));

        var args = $"--resolution {p.Dpi} --format tiff";
        _logger.LogInformation("scanimage {Args}", args);

        var psi = new ProcessStartInfo(ToolPaths.ScanImage, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        using var proc = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start scanimage");

        // Expected raw-pixel bytes for an A4-ish page at this dpi. We
        // overestimate slightly (8.5 × 11.7 in) so progress doesn't hit
        // 100 % mid-scan; final 100 fires after the process exits.
        long expectedBytes = (long)(8.5 * 11.7 * p.Dpi * p.Dpi * 3);

        var tiffStream = Pool.GetStream("scan-tiff");
        try
        {
            var stderrTask = proc.StandardError.ReadToEndAsync(ct);
            var buffer = new byte[64 * 1024];
            long totalRead = 0;
            int lastReportedPct = -5;
            while (true)
            {
                var n = await proc.StandardOutput.BaseStream.ReadAsync(buffer, ct);
                if (n <= 0) break;
                await tiffStream.WriteAsync(buffer.AsMemory(0, n), ct);
                totalRead += n;
                if (progress is not null && expectedBytes > 0)
                {
                    var pct = (int)Math.Min(99, totalRead * 100 / expectedBytes);
                    if (pct - lastReportedPct >= 5)
                    {
                        progress.Report(pct);
                        lastReportedPct = pct;
                    }
                }
            }
            await proc.WaitForExitAsync(ct);
            var stderr = await stderrTask;

            if (proc.ExitCode != 0)
                throw new InvalidOperationException(
                    $"scanimage exited {proc.ExitCode}: {stderr.Trim()}");

            var tiffBytes = tiffStream.Length;
            tiffStream.Position = 0;
            total.Stop();
            var throughput = total.Elapsed.TotalSeconds > 0
                ? tiffBytes / 1024.0 / 1024.0 / total.Elapsed.TotalSeconds
                : 0;
            _logger.LogInformation(
                "scan done: {Bytes} in {Elapsed:F2}s ({Mbps:F1} MB/s) rss={Rss} heap={Heap}",
                Fmt(tiffBytes), total.Elapsed.TotalSeconds, throughput,
                Fmt(MemRss()), Fmt(MemManaged()));
            progress?.Report(100);
            return tiffStream;
        }
        catch
        {
            tiffStream.Dispose();
            throw;
        }
    }
}
