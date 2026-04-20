using Microsoft.Extensions.Hosting;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Polls USB sysfs for the Epson V33 device node every couple of seconds,
/// emits <see cref="SessionEventType.ScannerOnline"/> / <c>ScannerOffline</c>
/// transitions on the event bus. Cheap (reads two small files per USB device),
/// doesn't touch the SANE plugin, safe to run during scans.
/// </summary>
public sealed class ScannerMonitor : BackgroundService
{
    private const string UsbVendorId = "04b8";
    private const string UsbProductId = "0142";
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(3);

    private readonly EventBroker _broker;
    private readonly ILogger<ScannerMonitor> _logger;
    private bool _lastOnline;

    public ScannerMonitor(EventBroker broker, ILogger<ScannerMonitor> logger)
    {
        _broker = broker;
        _logger = logger;
    }

    public bool IsOnline() => ScanUsbBus();

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // Prime the "last" state so the first real transition fires an event.
        _lastOnline = ScanUsbBus();
        _logger.LogInformation("scanner monitor: initial online={Online}", _lastOnline);

        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(PollInterval, ct); }
            catch (OperationCanceledException) { return; }

            var online = ScanUsbBus();
            if (online != _lastOnline)
            {
                _logger.LogInformation("scanner went {State}", online ? "online" : "offline");
                _broker.Publish(new SessionEvent(
                    online ? SessionEventType.ScannerOnline : SessionEventType.ScannerOffline));
                _lastOnline = online;
            }
        }
    }

    private static bool ScanUsbBus()
    {
        // /sys/bus/usb/devices/ has one subdirectory per device. Each has
        // idVendor / idProduct files containing the 4-char hex IDs.
        try
        {
            foreach (var dir in Directory.EnumerateDirectories("/sys/bus/usb/devices/"))
            {
                try
                {
                    var v = File.ReadAllText(Path.Combine(dir, "idVendor")).Trim();
                    if (v != UsbVendorId) continue;
                    var p = File.ReadAllText(Path.Combine(dir, "idProduct")).Trim();
                    if (p == UsbProductId) return true;
                }
                catch
                {
                    // not a device dir, or transient gone-away — ignore
                }
            }
        }
        catch (DirectoryNotFoundException)
        {
            // /sys/bus/usb not present (shouldn't happen on Linux) — treat as offline
        }
        return false;
    }
}
