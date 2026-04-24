using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Hosting.Systemd;
using PrintScan.Daemon;
using PrintScan.Shared;

// Startup-phase timing probe. The daemon takes ~16 s on an RPi 4 between
// systemd "Starting" and our first LogInformation — way higher than
// expected for a minimal ASP.NET app. These Console.WriteLines are written
// straight to stderr (systemd captures them into the journal); they're
// independent of the logging pipeline, which isn't live until after Build().
var _bootSw = System.Diagnostics.Stopwatch.StartNew();
static void BootLog(System.Diagnostics.Stopwatch sw, string phase) =>
    Console.Error.WriteLine($"[boot +{sw.ElapsedMilliseconds,6} ms] {phase}");
BootLog(_bootSw, "entered Main (CLR init complete)");

// Subscribe to AssemblyLoad before CreateBuilder so we see the load wave
// it triggers. Each line shows the cumulative ms at load — a load "wave"
// concentrated around a specific time tells us which phase is heavy.
AppDomain.CurrentDomain.AssemblyLoad += (_, e) =>
    Console.Error.WriteLine(
        $"[boot +{_bootSw.ElapsedMilliseconds,6} ms] asm: {e.LoadedAssembly.GetName().Name}");

// EventListener for CLR runtime JIT/Loader events. If JIT is dominating
// we'll see hundreds of method-compile events; if not, we've ruled it out.
// Keywords: JitKeyword=0x10, LoaderKeyword=0x8, TypeKeyword=0x80,
// GCKeyword=0x1. EventLevel.Informational keeps volume sane.
var _runtimeListener = new PrintScan.Daemon.BootEventListener(_bootSw);

// Pin ContentRoot to the binary directory. Default is Environment.CurrentDirectory,
// which is "/" under systemd — and a "/" ContentRoot torpedoes startup
// (see the JSON-source drop below for the mechanism). Even with the JSON
// sources removed, a deterministic ContentRoot is what ASP.NET semantically
// expects.
var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});

// Drop the default JSON config sources (appsettings.json +
// appsettings.{Environment}.json). CreateBuilder adds them with
// reloadOnChange: true, which installs a PhysicalFilesWatcher. On Linux
// that translates to per-subdirectory inotify_add_watch calls across the
// ContentRoot tree. We don't ship or read appsettings.json at all — env
// vars and args cover our (very small) config surface — so the watcher is
// pure overhead. Removing the source disposes the provider and its watcher.
// Observed cost on a Pi 4 with CWD=/: 16 s and ~84 000 stat calls inside
// CreateBuilder.
var jsonSources = builder.Configuration.Sources
    .OfType<Microsoft.Extensions.Configuration.Json.JsonConfigurationSource>()
    .ToList();
foreach (var src in jsonSources) builder.Configuration.Sources.Remove(src);

BootLog(_bootSw, "WebApplication.CreateBuilder done");
_runtimeListener.Summarize();

builder.Host.UseSystemd();
BootLog(_bootSw, "UseSystemd done");

// Bot and daemon both use System.Text.Json but the bot opts into
// JsonStringEnumConverter (ScanFormat serialized as "Jpeg"/"Png"/"Tiff").
// Minimal-APIs' default serializer expects enums as integers, so without
// this bot requests get 400 Bad Request on the enum field. Register the
// string-enum converter on the daemon side so both sides agree.
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.Converters.Add(
        new System.Text.Json.Serialization.JsonStringEnumConverter());
});

// Systemd socket activation — we REQUIRE fd 3 from systemd. Running
// without LISTEN_FDS means the socket unit didn't activate us properly
// and Kestrel would silently fall back to its default TCP binding on
// :5000, which nothing talks to. Fail fast instead of half-serving.
var listenFds = Environment.GetEnvironmentVariable("LISTEN_FDS");
if (listenFds is null || !int.TryParse(listenFds, out var fdCount) || fdCount <= 0)
{
    // Top-level-statements: throw to exit non-zero.
    throw new InvalidOperationException(
        "LISTEN_FDS not set — this daemon only serves the systemd-activated "
        + "Unix socket. Start via `systemctl start printscan-daemon.socket` "
        + "and ensure the service is Requires=printscan-daemon.socket.");
}
builder.WebHost.ConfigureKestrel(options => options.ListenHandle(3));

// systemd sets STATE_DIRECTORY when StateDirectory= is configured.
// Fall back to /var/lib/printscan when running outside systemd.
var stateDir = Environment.GetEnvironmentVariable("STATE_DIRECTORY")?.Split(':')[0]
    ?? "/var/lib/printscan";

builder.Services.AddSingleton(new SessionStore(stateDir));
builder.Services.AddSingleton<EventBroker>();
builder.Services.AddSingleton<ScanPipeline>();
builder.Services.AddSingleton<PrintService>();
builder.Services.AddSingleton<SessionService>();

// ShutdownGate and ScannerMonitor need to be both injectable and hosted.
builder.Services.AddSingleton<ShutdownGate>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<ShutdownGate>());
builder.Services.AddSingleton<ScannerMonitor>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<ScannerMonitor>());
builder.Services.AddSingleton<ButtonPoller>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<ButtonPoller>());
BootLog(_bootSw, "service registration done");

var app = builder.Build();
BootLog(_bootSw, "builder.Build() done");

// ── Status ──────────────────────────────────────────────────────────────────

app.MapGet("/status", (PrintService print, ScannerMonitor mon) =>
    Results.Ok(new DeviceStatus(
        print.GetStatus(),
        new ScannerStatus(mon.IsOnline()))));

// ── Print (unchanged shape) ─────────────────────────────────────────────────

app.MapPost("/print", async (HttpRequest request, PrintService print, ShutdownGate gate, CancellationToken ct) =>
{
    var form = await request.ReadFormAsync(ct);
    var file = form.Files.FirstOrDefault();
    if (file is null) return Results.BadRequest("No file provided");

    var pageRange = form["pageRange"].FirstOrDefault();
    var copies = int.TryParse(form["copies"].FirstOrDefault(), out var c) ? c : 1;
    using var ms = new MemoryStream();
    await file.CopyToAsync(ms, ct);

    using var _ = gate.Begin("print");
    var ok = await print.PrintAsync(
        new PrintRequest(file.FileName, ms.ToArray(), pageRange, copies), ct);
    return ok ? Results.Ok("Printed") : Results.StatusCode(500);
});

// ── Sessions ────────────────────────────────────────────────────────────────

app.MapPost("/sessions", (HttpRequest req, OpenSessionRequest body, SessionService svc) =>
{
    var takeover = string.Equals(req.Query["takeover"].ToString(), "true",
        StringComparison.OrdinalIgnoreCase);
    var (outcome, session, existing) = svc.TryOpen(body, takeover);
    return outcome switch
    {
        SessionService.OpenOutcome.Opened => Results.Created($"/sessions/{session!.Id}", session),
        SessionService.OpenOutcome.Conflict => Results.Conflict(
            new SessionConflict(existing!,
                $"Session already active for {existing!.OwnerDisplayName}; retry with ?takeover=true to reclaim.")),
        _ => Results.StatusCode(500)
    };
});

app.MapGet("/sessions/{id}", (string id, SessionService svc) =>
{
    var cur = svc.Current;
    if (cur is null || cur.Id != id) return Results.NotFound();
    return Results.Ok(cur);
});

app.MapPatch("/sessions/{id}", (string id, ScanParams newParams, SessionService svc) =>
{
    try
    {
        var updated = svc.UpdateParams(id, newParams);
        return Results.Ok(updated);
    }
    catch (InvalidOperationException ex)
    {
        return Results.BadRequest(ex.Message);
    }
});

app.MapDelete("/sessions/{id}", (string id, SessionService svc) =>
{
    var ok = svc.Close(id, SessionTerminationReason.Closed);
    return ok ? Results.NoContent() : Results.NotFound();
});

app.MapPost("/sessions/{id}/scan", async (string id, SessionService svc, CancellationToken ct) =>
{
    try
    {
        var seq = await svc.RequestScanAsync(id, ct);
        return Results.Accepted($"/sessions/{id}/image/{seq}", new { sessionId = id, seq });
    }
    catch (InvalidOperationException ex)
    {
        return Results.BadRequest(ex.Message);
    }
    catch (Exception ex)
    {
        return Results.Problem(ex.Message, statusCode: 500);
    }
});

// Each scan may yield multiple encoded variants (one per format bit in
// ScanParams.Format). The legacy URL `/image/{seq}` defaults to variant 0;
// `/image/{seq}/{variant}` selects a specific variant; `/image/{seq}/thumb`
// returns the small shared JPEG thumbnail the bot passes to Telegram
// so every variant renders a consistent preview in-chat.
app.MapGet("/sessions/{id}/image/{seq:int}/{variant:int}",
    async (string id, int seq, int variant, SessionService svc, HttpResponse response, CancellationToken ct) =>
        await ServeImage(id, seq, variant, svc, response, ct));
app.MapGet("/sessions/{id}/image/{seq:int}",
    async (string id, int seq, SessionService svc, HttpResponse response, CancellationToken ct) =>
        await ServeImage(id, seq, 0, svc, response, ct));
app.MapGet("/sessions/{id}/image/{seq:int}/thumb",
    async (string id, int seq, SessionService svc, HttpResponse response, CancellationToken ct) =>
{
    var thumb = svc.GetThumbnail(id, seq);
    if (thumb is null) return Results.NotFound();
    response.ContentType = thumb.ContentType;
    response.Headers.ContentDisposition =
        $"attachment; filename=\"{thumb.FileName}\"";
    thumb.Data.Position = 0;
    await thumb.Data.CopyToAsync(response.Body, ct);
    return Results.Empty;
});

static async Task<IResult> ServeImage(
    string id, int seq, int variant, SessionService svc, HttpResponse response, CancellationToken ct)
{
    var img = svc.GetImage(id, seq, variant);
    if (img is null) return Results.NotFound();
    response.ContentType = img.ContentType;
    response.Headers.ContentDisposition =
        $"attachment; filename=\"{img.FileName}\"";
    img.Data.Position = 0;
    await img.Data.CopyToAsync(response.Body, ct);
    return Results.Empty;
}

// ── Debug / test hooks ──────────────────────────────────────────────────────

// Simulate a scanner button press — used for end-to-end testing of the
// session → bot-reactive-scan path without physical hardware access.
app.MapPost("/debug/button", (ButtonPoller poller) =>
{
    poller.SimulatePress();
    return Results.NoContent();
});

// ── Server-Sent Events ──────────────────────────────────────────────────────

app.MapGet("/events", async (HttpContext ctx, EventBroker broker, SessionService svc, CancellationToken ct) =>
{
    ctx.Response.Headers.CacheControl = "no-cache";
    ctx.Response.Headers.ContentType = "text/event-stream";
    ctx.Features.Get<IHttpResponseBodyFeature>()?.DisableBuffering();

    var reader = broker.Subscribe(out var token);

    // Prime a freshly-connected subscriber with the current session (if any),
    // so it can rebuild state without extra GETs.
    var current = svc.Current;
    if (current is not null)
    {
        var primer = new SessionEvent(SessionEventType.SessionOpened,
            Session: current, SessionId: current.Id);
        await ctx.Response.WriteAsync(EventBroker.FormatSse(primer), ct);
        await ctx.Response.Body.FlushAsync(ct);
    }

    try
    {
        await foreach (var ev in reader.ReadAllAsync(ct))
        {
            await ctx.Response.WriteAsync(EventBroker.FormatSse(ev), ct);
            await ctx.Response.Body.FlushAsync(ct);
        }
    }
    catch (OperationCanceledException) { /* client disconnected */ }
    finally
    {
        broker.Unsubscribe(token);
    }
});

BootLog(_bootSw, "endpoint mapping done, about to start host");
app.Logger.LogInformation("PrintScan daemon starting (state={StateDir})", stateDir);

// Shutdown-phase diagnostic logging. The 2026-04-21 hang showed the
// process stuck in futex_wait on the main thread — classic sync-over-
// async deadlock — for 2+ minutes after "All in-flight ops drained".
// Logs below pinpoint which shutdown phase any future hang reaches.
//
// We intentionally do NOT register a DisposeAsync callback here —
// SessionService implements IAsyncDisposable, and the DI container
// calls that naturally during host shutdown. A manual callback with
// .GetAwaiter().GetResult() blocked the shutdown thread and was the
// root cause of the previous hang.
var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();
lifetime.ApplicationStopping.Register(() =>
    app.Logger.LogInformation("lifetime: ApplicationStopping fired"));
lifetime.ApplicationStopped.Register(() =>
{
    app.Logger.LogInformation("lifetime: ApplicationStopped fired");

    // Diagnostic capture for the post-stopped hang observed on
    // 2026-04-23: after this callback fires, after every hosted
    // service's StopAsync returns, after every IAsyncDisposable's
    // DisposeAsync completes, the CLR process nonetheless refuses
    // to exit — systemd waits out the full TimeoutStopSec before
    // sending SIGKILL. Something framework-internal (Kestrel socket
    // teardown? non-daemon thread in a native lib?) keeps the
    // process alive past any code we own.
    //
    // Two complementary captures (kernel-only stacks would show all
    // threads in futex_wait / ep_poll — accurate but unhelpful
    // without managed context):
    //
    //   1. /proc/<pid>/task/<tid>/stack → kernel syscall each thread
    //      is blocked in. Cheap, always works.
    //   2. createdump <pid> -f <path> → a .core file of the whole
    //      process, including managed heap + thread states, which we
    //      can scp off and analyze offline with `dotnet-dump analyze`
    //      (equivalent to WinDbg + SOS: `clrstack -all`, `threads`,
    //      `dumpheap`, etc.). createdump ships with every .NET
    //      runtime as a sibling of System.Private.CoreLib.dll.
    //
    // Then let systemd SIGKILL at the real timeout so next-time
    // evidence is preserved.
    _ = Task.Run(async () =>
    {
        await Task.Delay(TimeSpan.FromSeconds(10));
        var log = app.Logger;
        var pid = Environment.ProcessId;
        log.LogWarning(
            "lingering {Seconds}s after ApplicationStopped — dumping diagnostics (pid={Pid})",
            10, pid);

        // ── 1. per-thread kernel stack dump ────────────────────────
        try
        {
            foreach (var tdir in Directory.EnumerateDirectories($"/proc/{pid}/task"))
            {
                var tid = Path.GetFileName(tdir);
                string comm = "?", state = "?", stack = "?";
                try { comm = File.ReadAllText(Path.Combine(tdir, "comm")).TrimEnd(); } catch { }
                try
                {
                    var statLine = File.ReadAllText(Path.Combine(tdir, "stat"));
                    // stat field 3 is state (R/S/D/Z/T/...); split carefully
                    // because comm (field 2) can contain spaces, delimited by
                    // parentheses.
                    var rp = statLine.LastIndexOf(')');
                    if (rp >= 0 && rp + 2 < statLine.Length)
                        state = statLine[rp + 2].ToString();
                }
                catch { }
                try { stack = File.ReadAllText(Path.Combine(tdir, "stack")).TrimEnd(); }
                catch (Exception ex) { stack = $"(unreadable: {ex.Message})"; }
                log.LogWarning("thread tid={Tid} comm={Comm} state={State}\n{Stack}",
                    tid, comm, state, stack);
            }
        }
        catch (Exception ex)
        {
            log.LogWarning(ex, "thread stack enumeration failed");
        }

        // ── 2. createdump: managed-aware full process core ─────────
        try
        {
            // createdump is shipped alongside CoreCLR. System.Private
            // .CoreLib.dll lives in the runtime directory, so its
            // directory is where we find createdump.
            var coreclrDir = Path.GetDirectoryName(typeof(object).Assembly.Location)!;
            var createdumpPath = Path.Combine(coreclrDir, "createdump");
            var ts = DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss");
            var dumpDir = Environment.GetEnvironmentVariable("STATE_DIRECTORY")?.Split(':')[0]
                ?? "/var/lib/printscan";
            var dumpPath = Path.Combine(dumpDir, $"hang-{ts}.core");
            log.LogWarning("creating managed-aware core dump via {Cd} → {Path}",
                createdumpPath, dumpPath);

            // -f <file>     : output path
            // --normal      : full core (default); smaller options exist but we
            //                 want complete managed-heap context for analysis
            var psi = new System.Diagnostics.ProcessStartInfo(createdumpPath)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            psi.ArgumentList.Add("-f");
            psi.ArgumentList.Add(dumpPath);
            psi.ArgumentList.Add("--normal");
            psi.ArgumentList.Add(pid.ToString());
            using var proc = System.Diagnostics.Process.Start(psi);
            if (proc is not null)
            {
                // createdump is a quick pause-and-snapshot; should finish
                // in seconds. Cap in case something goes sideways.
                if (await Task.Run(() => proc.WaitForExit(30_000)))
                {
                    log.LogWarning(
                        "createdump finished rc={Rc}. Analyze with: dotnet-dump analyze {Path}",
                        proc.ExitCode, dumpPath);
                    var err = await proc.StandardError.ReadToEndAsync();
                    if (!string.IsNullOrWhiteSpace(err))
                        log.LogWarning("createdump stderr: {Err}", err.TrimEnd());
                }
                else
                {
                    log.LogWarning("createdump did not finish within 30s — killing");
                    try { proc.Kill(entireProcessTree: true); } catch { }
                }
            }
        }
        catch (Exception ex)
        {
            log.LogWarning(ex, "createdump invocation failed — offline managed-stack analysis unavailable for this hang");
        }

        log.LogWarning("diagnostic dump complete; leaving the rest to systemd's TimeoutStopSec (SIGKILL)");
    });
});

app.Run();
app.Logger.LogInformation("main: app.Run returned, about to exit");
