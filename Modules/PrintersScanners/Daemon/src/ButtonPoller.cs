using Microsoft.Extensions.Hosting;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Detects physical Scan-button presses on the Epson V33 and publishes
/// <see cref="SessionEventType.ScannerButton"/> events on the broker.
///
/// ──────────────────────────────────────────────────────────────────────
/// Status: scaffold. The event plumbing (broker fan-out, coordination
/// with ScannerMonitor/SessionService, rising-edge detection, debouncing)
/// is complete and exercised by <see cref="SimulatePress"/>. The actual
/// USB query (<c>DoUsbPoll</c>) is a stub — it needs to be fleshed out
/// once we've reverse-engineered the ESC/I button response format on real
/// hardware (see <c>probe-button.py</c> under EpkowaScanner/).
/// ──────────────────────────────────────────────────────────────────────
///
/// Coordination rules:
///   • Skip polling while the scanner is offline (no USB device → no poll target).
///   • Skip polling while a scan is in flight — SANE has the USB device
///     claimed, our bulk query would fight for endpoint access.
///   • Rising-edge only: emit on pressed→not-pressed→pressed, suppress
///     the sustained-press state.
/// </summary>
public sealed class ButtonPoller : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(1000);
    private static readonly TimeSpan IdleBackoff = TimeSpan.FromMilliseconds(1000);

    private readonly EventBroker _broker;
    private readonly ScannerMonitor _scanner;
    private readonly SessionService _sessions;
    private readonly ILogger<ButtonPoller> _logger;

    // Previous polled state for edge detection. Null = unknown (e.g. just
    // came online, no poll yet) — first observed press after that is valid.
    private bool? _lastPressed;

    // For ad-hoc testing — POST /debug/button hits this.
    private readonly SemaphoreSlim _simulate = new(0, 1);

    public ButtonPoller(
        EventBroker broker, ScannerMonitor scanner, SessionService sessions,
        ILogger<ButtonPoller> logger)
    {
        _broker = broker;
        _scanner = scanner;
        _sessions = sessions;
        _logger = logger;
    }

    /// <summary>
    /// Dev/test hook — fake a button press. Emits the event immediately,
    /// no USB poll. Wired to <c>POST /debug/button</c>.
    /// </summary>
    public void SimulatePress()
    {
        _logger.LogInformation("simulated button press");
        _simulate.Release();
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _logger.LogInformation("button poller started (real USB poll: NOT IMPLEMENTED — hardware probe pending)");

        while (!ct.IsCancellationRequested)
        {
            // Let simulated presses through regardless of scanner state —
            // they're the test path.
            if (await _simulate.WaitAsync(TimeSpan.Zero, ct))
            {
                EmitButton();
                continue;
            }

            if (!_scanner.IsOnline() || (_sessions.Current?.InFlightScan ?? false))
            {
                _lastPressed = null;  // reset edge detector on offline/busy
                await SafeDelay(IdleBackoff, ct);
                continue;
            }

            bool? pressed = null;
            try
            {
                pressed = await DoUsbPollAsync(ct);
            }
            catch (Exception ex)
            {
                _logger.LogDebug("button poll failed: {Err}", ex.Message);
            }

            if (pressed is true && _lastPressed is false)
                EmitButton();
            _lastPressed = pressed;

            await SafeDelay(PollInterval, ct);
        }
    }

    private void EmitButton() =>
        _broker.Publish(new SessionEvent(SessionEventType.ScannerButton));

    private static async Task SafeDelay(TimeSpan d, CancellationToken ct)
    {
        try { await Task.Delay(d, ct); } catch (OperationCanceledException) { }
    }

    /// <summary>
    /// Stub: the real work. Should open /dev/bus/usb/…/… for the scanner
    /// (VID 04b8 / PID 0142), send an ESC ! bulk write, read the response,
    /// decode the button bits. Returns true if the Scan button is currently
    /// pressed, false if not, null if the poll itself failed.
    ///
    /// TODO (hardware required):
    ///   1. Run probe-button.py on the Pi with the scanner attached; note
    ///      the 4-byte response bytes while the Scan button is pressed vs.
    ///      released.
    ///   2. Identify the bit (likely bit 0 of byte 2 or 3 by analogy with
    ///      scanbuttond/backends/epson.c — but V33 may differ).
    ///   3. Pick a libusb binding: LibUsbDotNet (NuGet, simplest), or a
    ///      small Rust sidecar exec'd by the daemon (keeps C# free of
    ///      native deps), or P/Invoke to libusb.so directly.
    ///   4. Implement open/claim/write/read/release here; watch out for
    ///      the SANE device lock — we only poll when Current.InFlightScan
    ///      is false, but SANE may still hold the device briefly on the
    ///      edges of scans. Retry on USBDEVFS_CLAIMINTERFACE EBUSY.
    /// </summary>
    private static Task<bool?> DoUsbPollAsync(CancellationToken ct)
    {
        return Task.FromResult<bool?>(null);
    }
}
