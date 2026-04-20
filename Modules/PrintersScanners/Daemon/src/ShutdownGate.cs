using Microsoft.Extensions.Hosting;

namespace PrintScan.Daemon;

/// <summary>
/// Counter of in-flight operations (scans + uploads) that must complete before
/// the service is allowed to exit. On SIGTERM, <see cref="IHostedService.StopAsync"/>
/// blocks until the counter drains; systemd's TimeoutStopSec bounds the wait.
/// </summary>
public sealed class ShutdownGate : IHostedService
{
    private readonly SemaphoreSlim _drained = new(initialCount: 1, maxCount: 1);
    private int _inFlight;
    private readonly object _lock = new();
    private readonly ILogger<ShutdownGate> _logger;
    private bool _stopping;

    public ShutdownGate(ILogger<ShutdownGate> logger) { _logger = logger; }

    /// <summary>
    /// Register the start of an in-flight operation. Dispose the returned
    /// handle (preferably with <c>using</c>) to mark it completed.
    /// </summary>
    public IDisposable Begin(string label)
    {
        lock (_lock)
        {
            if (_stopping)
                throw new InvalidOperationException(
                    $"Refusing new operation '{label}' — service is stopping");
            if (_inFlight == 0)
                _drained.Wait();   // take the "drained" permit while work is pending
            _inFlight++;
        }
        return new Handle(this, label);
    }

    private void End(string label)
    {
        lock (_lock)
        {
            _inFlight--;
            if (_inFlight == 0)
                _drained.Release();
        }
        _logger.LogDebug("op '{Label}' complete, inflight={Count}", label, _inFlight);
    }

    public Task StartAsync(CancellationToken ct) => Task.CompletedTask;

    public async Task StopAsync(CancellationToken ct)
    {
        lock (_lock) { _stopping = true; }
        _logger.LogInformation("SIGTERM received — waiting for in-flight ops to drain (currently {N})", _inFlight);
        // Wait on the "drained" semaphore. If nothing is in flight we take
        // and immediately release; otherwise we block until End() releases it.
        await _drained.WaitAsync(ct);
        _drained.Release();
        _logger.LogInformation("All in-flight ops drained — shutting down cleanly");
    }

    private sealed class Handle : IDisposable
    {
        private readonly ShutdownGate _gate;
        private readonly string _label;
        private int _disposed;
        public Handle(ShutdownGate gate, string label) { _gate = gate; _label = label; }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 0) _gate.End(_label);
        }
    }
}
