using System.Diagnostics;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Print backend. The two implementations live in one class so the
/// switch is a single flag — useful for "wire the bot up against a
/// host with no physical printer" (stub) and for production runs
/// (cups). The public surface and request/response shapes are the
/// same in either mode, so the bot's print UX exercises identical
/// code paths regardless of backend.
/// </summary>
public sealed class PrintService
{
    private readonly ILogger<PrintService> _logger;
    private readonly string _mediaSize;
    private readonly PrintableMargins _margins;
    private readonly bool _useStub;
    private readonly string _lpBin;
    private readonly string _lpstatBin;
    // Null → let CUPS pick the system default destination (set via
    // `lpadmin -d <queue>`). When the box has exactly one queue this
    // is the convenient default; pin via PRINTSCAN_PRINTER_NAME for
    // hosts with multiple queues.
    private readonly string? _printerName;
    // USB vendor:product pairs of the physical printer(s) we manage,
    // as hex (e.g. "03f0:3817" for the HP LaserJet P2015). When set,
    // we probe /sys/bus/usb/devices/ before trusting `lpstat`'s
    // queue-state output, so a powered-off / unplugged printer is
    // reported offline even when the CUPS queue is `enabled`. Comma-
    // separated for hosts with multiple printers. Null disables the
    // probe — daemon falls back to lpstat-only (the old behaviour).
    private readonly string[] _printerUsbIds;

    public PrintService(
        ILogger<PrintService> logger,
        string mediaSize,
        PrintableMargins margins,
        bool useStub,
        string lpBin,
        string lpstatBin,
        string? printerName,
        string? printerUsbIds)
    {
        _logger = logger;
        _mediaSize = mediaSize;
        _margins = margins;
        _useStub = useStub;
        _lpBin = lpBin;
        _lpstatBin = lpstatBin;
        _printerName = string.IsNullOrWhiteSpace(printerName) ? null : printerName;
        _printerUsbIds = string.IsNullOrWhiteSpace(printerUsbIds)
            ? Array.Empty<string>()
            : printerUsbIds
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(s => s.ToLowerInvariant())
                .ToArray();
    }

    public PrinterStatus GetStatus() =>
        _useStub ? GetStubStatus() : GetCupsStatus();

    public Task<bool> PrintAsync(PrintRequest request, CancellationToken ct) =>
        _useStub ? StubPrintAsync(request, ct) : CupsPrintAsync(request, ct);

    // ── Stub backend ────────────────────────────────────────────────────────

    private PrinterStatus GetStubStatus() =>
        new(Online: true,
            StatusText: $"stub printer ({_mediaSize}, no physical device wired up)",
            MediaSize: _mediaSize,
            Margins: _margins);

    private async Task<bool> StubPrintAsync(PrintRequest request, CancellationToken ct)
    {
        _logger.LogInformation(
            "STUB PRINT: {File} ({Bytes} bytes), copies={Copies}, " +
            "pages={Pages}, set={Set}, scale={Scale}, orient={Orient}",
            request.FileName, request.FileData.Length, request.Copies,
            request.PageRange ?? "all", request.PageSelection,
            request.Scale, request.Orientation);

        // End-to-end test path: dump the would-have-printed bytes under
        // <STATE_DIRECTORY>/printed/ so the operator can inspect exactly
        // what would have hit CUPS, without burning paper.
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

        // Simulated processing time so the bot's "🖨 printing…"
        // intermediate state is visible briefly.
        try { await Task.Delay(TimeSpan.FromSeconds(2), ct); }
        catch (OperationCanceledException) { return false; }

        _logger.LogInformation("STUB PRINT done: {File}", request.FileName);
        return true;
    }

    // ── CUPS backend ────────────────────────────────────────────────────────

    /// <summary>
    /// Returns true if any configured USB vendor:product pair is
    /// currently present under /sys/bus/usb/devices/. When no IDs
    /// are configured we assume "online" — the caller treats that
    /// as "skip the USB probe, just trust lpstat".
    /// </summary>
    private bool IsConfiguredUsbPrinterConnected()
    {
        if (_printerUsbIds.Length == 0) return true;
        // Each immediate child of /sys/bus/usb/devices/ that has
        // both idVendor and idProduct files is a USB device (vs an
        // interface or hub root). Walk them, read the pair, compare.
        // We don't follow into subdirs — interfaces live there and
        // their idVendor inheritance would cause spurious matches.
        const string root = "/sys/bus/usb/devices";
        IEnumerable<string> dirs;
        try { dirs = Directory.EnumerateDirectories(root); }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "USB probe: failed to enumerate {Root}", root);
            return true;  // /sys unavailable → don't second-guess lpstat
        }
        foreach (var dir in dirs)
        {
            try
            {
                var vidPath = Path.Combine(dir, "idVendor");
                var pidPath = Path.Combine(dir, "idProduct");
                if (!File.Exists(vidPath) || !File.Exists(pidPath)) continue;
                var vid = File.ReadAllText(vidPath).Trim().ToLowerInvariant();
                var pid = File.ReadAllText(pidPath).Trim().ToLowerInvariant();
                var pair = $"{vid}:{pid}";
                if (Array.IndexOf(_printerUsbIds, pair) >= 0)
                    return true;
            }
            catch
            {
                // Race with device removal between EnumerateDirectories
                // and ReadAllText; skip silently.
            }
        }
        return false;
    }

    private PrinterStatus GetCupsStatus()
    {
        // Short-circuit on USB-absent: CUPS only re-evaluates the
        // device link when it actually tries to dispatch a job, so a
        // powered-off / unplugged printer keeps reporting `is idle.
        // enabled` indefinitely. Probing /sys/bus/usb/devices/ here
        // lets us report offline immediately when the operator pulls
        // power, rather than waiting until the next print attempt
        // fails. Skipped (returns true) when no USB IDs are
        // configured — falls back to the lpstat-only behaviour.
        if (!IsConfiguredUsbPrinterConnected())
        {
            return new(Online: false,
                StatusText: $"printer not connected (no USB device matching {string.Join(',', _printerUsbIds)})",
                MediaSize: _mediaSize,
                Margins: _margins);
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = _lpstatBin,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            // `lpstat -p [printer]` prints one line per queue:
            //   "printer HP_LaserJet_P2015n is idle.  enabled since …"
            //   "printer HP_LaserJet_P2015n now printing job-N. enabled since …"
            //   "printer HP_LaserJet_P2015n disabled since … - … reason …"
            psi.ArgumentList.Add("-p");
            if (_printerName is not null)
                psi.ArgumentList.Add(_printerName);

            using var proc = Process.Start(psi)
                ?? throw new InvalidOperationException($"failed to start {_lpstatBin}");
            var stdout = proc.StandardOutput.ReadToEnd();
            var stderr = proc.StandardError.ReadToEnd();
            proc.WaitForExit();

            if (proc.ExitCode != 0)
            {
                var msg = string.IsNullOrWhiteSpace(stderr) ? "(no stderr)" : stderr.Trim();
                _logger.LogWarning("CUPS lpstat exit {Code}: {Err}", proc.ExitCode, msg);
                return new(Online: false,
                    StatusText: $"lpstat failed: {msg}",
                    MediaSize: _mediaSize,
                    Margins: _margins);
            }

            // No queues configured at all → lpstat returns 0 with empty output.
            // Render that as offline so the bot surfaces the missing-queue
            // state rather than reporting "online" without a target.
            if (string.IsNullOrWhiteSpace(stdout))
                return new(Online: false,
                    StatusText: $"no CUPS queues configured (lpstat -p {_printerName ?? "(default)"} empty)",
                    MediaSize: _mediaSize,
                    Margins: _margins);

            // First line gives "is idle / now printing / disabled". Anything
            // with the word "disabled" reads as offline; everything else
            // (idle / now printing) reads as online.
            var firstLine = stdout.Split('\n', 2)[0].Trim();
            var online = !firstLine.Contains("disabled", StringComparison.OrdinalIgnoreCase);
            return new(Online: online,
                StatusText: firstLine,
                MediaSize: _mediaSize,
                Margins: _margins);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "CUPS lpstat error");
            return new(Online: false,
                StatusText: $"lpstat error: {ex.Message}",
                MediaSize: _mediaSize,
                Margins: _margins);
        }
    }

    private async Task<bool> CupsPrintAsync(PrintRequest request, CancellationToken ct)
    {
        // Build the lp argv. Order doesn't matter to lp; we group by
        // "destination" → "metadata" → "job options" for readability
        // in the log line we emit below.
        var args = new List<string>();

        if (_printerName is not null)
        {
            args.Add("-d");
            args.Add(_printerName);
        }

        // Job title — what `lpq` / the CUPS web UI shows. Pass the
        // original filename so operator-side queue inspection is
        // self-explanatory.
        args.Add("-t");
        args.Add(request.FileName ?? "job");

        if (request.Copies > 1)
        {
            args.Add("-n");
            args.Add(request.Copies.ToString());
        }

        if (!string.IsNullOrEmpty(request.PageRange))
        {
            args.Add("-P");
            args.Add(request.PageRange);
        }

        if (request.PageSelection != PageSelection.All)
        {
            args.Add("-o");
            args.Add($"page-set={request.PageSelection.ToString().ToLowerInvariant()}");
        }

        // CUPS orientation-requested IPP attribute:
        //   3 = portrait, 4 = landscape (rotate 90° ccw).
        // For Auto we omit the option entirely and let CUPS / the
        // PPD pick — the bot pre-rotates raster jobs so this is
        // mostly a non-issue for image inputs.
        switch (request.Orientation)
        {
            case PrintOrientation.Portrait:
                args.Add("-o");
                args.Add("orientation-requested=3");
                break;
            case PrintOrientation.Landscape:
                args.Add("-o");
                args.Add("orientation-requested=4");
                break;
        }

        // Scale handling. The bot is the source of truth for raster
        // sizing — by the time bytes hit us they're already at the
        // intended pixel dimensions, so we only need to ask CUPS for
        // its built-in fit-to-page when the caller flagged Fit. Fill
        // and OneToOne intentionally don't translate to lp options
        // (Fill has no native CUPS equivalent for raster; OneToOne
        // means "respect content's own size").
        if (request.Scale == PrintScaleMode.Fit)
        {
            args.Add("-o");
            args.Add("fit-to-page");
        }

        _logger.LogInformation(
            "CUPS lp {Bin} {Args} ({Bytes} bytes from {File})",
            _lpBin, string.Join(' ', args), request.FileData.Length, request.FileName);

        var psi = new ProcessStartInfo
        {
            FileName = _lpBin,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        try
        {
            using var proc = Process.Start(psi)
                ?? throw new InvalidOperationException($"failed to start {_lpBin}");

            // Stream the file bytes into lp's stdin. lp auto-detects
            // the input format (PDF, PostScript, image/*, text) and
            // routes it through the appropriate CUPS filter chain.
            await proc.StandardInput.BaseStream.WriteAsync(request.FileData, ct);
            proc.StandardInput.Close();

            var stdoutTask = proc.StandardOutput.ReadToEndAsync(ct);
            var stderrTask = proc.StandardError.ReadToEndAsync(ct);
            await proc.WaitForExitAsync(ct);
            var stdout = (await stdoutTask).Trim();
            var stderr = (await stderrTask).Trim();

            if (proc.ExitCode == 0)
            {
                // lp prints "request id is HP_LaserJet_P2015n-42 (1 file(s))"
                // on success — surface it so the operator can correlate
                // with the CUPS job log if anything goes weird.
                _logger.LogInformation("CUPS lp accepted: {Out}", stdout);
                return true;
            }

            _logger.LogError("CUPS lp failed (exit {Code}): {Err}",
                proc.ExitCode, string.IsNullOrEmpty(stderr) ? stdout : stderr);
            return false;
        }
        catch (OperationCanceledException)
        {
            // Shutdown mid-print. Caller (the print endpoint) handles
            // returning a 5xx; we just need to not crash the daemon.
            _logger.LogWarning("CUPS lp cancelled mid-flight");
            return false;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "CUPS lp threw");
            return false;
        }
    }
}
