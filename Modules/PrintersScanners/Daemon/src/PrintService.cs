using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Stub printer — for end-to-end testing of the bot's print UX without
/// burning paper or toner. Reports the printer as online, accepts every
/// job, simulates a short processing delay, and logs what would have
/// gone to <c>lp</c>. Drop-in replacement for the future real
/// implementation: the public surface (<see cref="GetStatus"/>,
/// <see cref="PrintAsync"/>) and the request/response shapes are the
/// same, so swapping in a CUPS-backed version later doesn't ripple.
/// </summary>
public sealed class PrintService
{
    private readonly ILogger<PrintService> _logger;
    private readonly string _mediaSize;
    private readonly PrintableMargins _margins;
    public PrintService(
        ILogger<PrintService> logger,
        string mediaSize,
        PrintableMargins margins)
    {
        _logger = logger;
        _mediaSize = mediaSize;
        _margins = margins;
    }

    public PrinterStatus GetStatus() =>
        new(Online: true,
            StatusText: $"stub printer ({_mediaSize}, no physical device wired up)",
            MediaSize: _mediaSize,
            Margins: _margins);

    public async Task<bool> PrintAsync(PrintRequest request, CancellationToken ct)
    {
        _logger.LogInformation(
            "STUB PRINT: {File} ({Bytes} bytes), copies={Copies}, " +
            "pages={Pages}, set={Set}, scale={Scale}, orient={Orient}",
            request.FileName, request.FileData.Length, request.Copies,
            request.PageRange ?? "all", request.PageSelection,
            request.Scale, request.Orientation);

        // End-to-end test path: write whatever the bot handed us
        // verbatim into <STATE_DIRECTORY>/printed/. Lets the user
        // inspect what would have hit CUPS without burning paper.
        // When the real lp-driven implementation lands this will
        // be replaced by a CUPS subprocess; the file output stays
        // as an audit trail (the lp invocation's tee).
        try
        {
            var stateRoot = Environment.GetEnvironmentVariable("STATE_DIRECTORY")
                ?? "/var/lib/printscan-daemon";
            var outDir = Path.Combine(stateRoot, "printed");
            Directory.CreateDirectory(outDir);
            var stamp = DateTimeOffset.Now.ToString("yyyyMMdd-HHmmss-fff");
            var safeName = string.Concat((request.FileName ?? "job")
                .Select(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_'));
            var path = Path.Combine(outDir, $"{stamp}-{safeName}");
            await File.WriteAllBytesAsync(path, request.FileData, ct);
            _logger.LogInformation("STUB PRINT wrote: {Path}", path);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "STUB PRINT failed to write output file");
        }

        // Simulated processing time. A real Pi-attached HP LaserJet at
        // 100-150 ms per page is typical, but for a stub we just want
        // the bot's "🖨 printing…" intermediate state to be visible
        // briefly before we flip to "✅ done", not instantaneously.
        try { await Task.Delay(TimeSpan.FromSeconds(2), ct); }
        catch (OperationCanceledException) { return false; }

        _logger.LogInformation("STUB PRINT done: {File}", request.FileName);
        return true;
    }
}
