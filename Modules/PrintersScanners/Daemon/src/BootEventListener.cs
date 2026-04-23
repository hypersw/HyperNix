using System.Diagnostics;
using System.Diagnostics.Tracing;

namespace PrintScan.Daemon;

/// <summary>
/// Startup-phase introspection via EventPipe/EventListener. Subscribes to
/// CLR runtime events (JIT, loader, exceptions) and counts them. A dump
/// at the end of the heavy phase tells us whether JIT or something else
/// is responsible for the 15 s inside WebApplication.CreateBuilder.
/// </summary>
internal sealed class BootEventListener : EventListener
{
    private readonly Stopwatch _sw;
    private int _jitStart, _jitStop;
    private int _loaderAsmLoad, _loaderModLoad;
    private int _exceptions;
    private long _jitTotalIlBytes;

    public BootEventListener(Stopwatch sw) { _sw = sw; }

    protected override void OnEventSourceCreated(EventSource es)
    {
        // Microsoft-Windows-DotNETRuntime: JIT/Loader/Exception keywords.
        // Keyword bits from
        // https://learn.microsoft.com/en-us/dotnet/fundamentals/diagnostics/runtime-events.
        if (es.Name == "Microsoft-Windows-DotNETRuntime")
        {
            EnableEvents(es, EventLevel.Informational, (EventKeywords)(
                0x10  /* JIT */        |
                0x8   /* Loader */     |
                0x8000 /* Exception */));
        }
    }

    protected override void OnEventWritten(EventWrittenEventArgs ev)
    {
        switch (ev.EventName)
        {
            case "MethodJittingStarted":  _jitStart++;
                if (ev.Payload is { Count: > 0 } p && p[0] is long il) _jitTotalIlBytes += il;
                break;
            case "MethodLoadVerbose_V1":
            case "MethodLoad":            _jitStop++; break;
            case "AssemblyLoad_V1":
            case "LoaderAssemblyLoad":    _loaderAsmLoad++; break;
            case "ModuleLoad_V2":
            case "LoaderModuleLoad":      _loaderModLoad++; break;
            case "ExceptionThrown_V1":    _exceptions++; break;
        }
    }

    public void Summarize()
    {
        Console.Error.WriteLine(
            $"[boot +{_sw.ElapsedMilliseconds,6} ms] runtime: jit_start={_jitStart} jit_stop={_jitStop} " +
            $"jit_il={_jitTotalIlBytes} asm_load={_loaderAsmLoad} mod_load={_loaderModLoad} " +
            $"exceptions={_exceptions}");
    }
}
