using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Hosting.Systemd;
using PrintScan.Daemon;
using PrintScan.Shared;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseSystemd();

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

// Systemd socket activation — pick up fd 3 if LISTEN_FDS is set.
var listenFds = Environment.GetEnvironmentVariable("LISTEN_FDS");
if (listenFds is not null && int.TryParse(listenFds, out var fdCount) && fdCount > 0)
{
    builder.WebHost.ConfigureKestrel(options => options.ListenHandle(3));
}

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

var app = builder.Build();

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

app.MapGet("/sessions/{id}/image/{seq:int}",
    async (string id, int seq, SessionService svc, HttpResponse response, CancellationToken ct) =>
{
    var img = svc.GetImage(id, seq);
    if (img is null) return Results.NotFound();
    response.ContentType = img.ContentType;
    response.Headers.ContentDisposition =
        $"attachment; filename=\"{img.FileName}\"";
    img.Data.Position = 0;
    await img.Data.CopyToAsync(response.Body, ct);
    return Results.Empty;
});

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

app.Logger.LogInformation("PrintScan daemon starting (state={StateDir})", stateDir);

// Clean up session expiry timer on shutdown.
var lifetime = app.Services.GetRequiredService<IHostApplicationLifetime>();
lifetime.ApplicationStopping.Register(() =>
{
    var svc = app.Services.GetRequiredService<SessionService>();
    svc.DisposeAsync().AsTask().GetAwaiter().GetResult();
});

app.Run();
