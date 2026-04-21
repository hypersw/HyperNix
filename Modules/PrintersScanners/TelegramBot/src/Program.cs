using System.Net.Http.Headers;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using PrintScan.Shared;
using PrintScan.TelegramBot;
using Telegram.Bot;
using Telegram.Bot.Types;
using Telegram.Bot.Types.Enums;
using Telegram.Bot.Types.ReplyMarkups;

// ── Config ──────────────────────────────────────────────────────────────────

var socketPath = Environment.GetEnvironmentVariable("PRINTSCAN_SOCKET") ?? "/run/printscan/api.sock";

// Token: prefer PRINTSCAN_BOT_TOKEN_FILE, fallback to systemd credential dir.
var tokenFile = Environment.GetEnvironmentVariable("PRINTSCAN_BOT_TOKEN_FILE");
if (string.IsNullOrEmpty(tokenFile))
{
    var credDir = Environment.GetEnvironmentVariable("CREDENTIALS_DIRECTORY");
    tokenFile = credDir is not null ? Path.Combine(credDir, "telegram-token") : null;
}
if (string.IsNullOrEmpty(tokenFile) || !File.Exists(tokenFile))
    throw new Exception($"Bot token file not found (tried {tokenFile})");

// systemd sets RUNTIME_DIRECTORY when RuntimeDirectory= is configured.
var runtimeDir = Environment.GetEnvironmentVariable("RUNTIME_DIRECTORY")?.Split(':')[0]
    ?? "/run/printscan-bot";

var allowedUsersJson = Environment.GetEnvironmentVariable("PRINTSCAN_ALLOWED_USERS") ?? "[]";
var allowedUsers = (System.Text.Json.JsonSerializer.Deserialize<List<AllowedUser>>(
    allowedUsersJson,
    new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [])
    .ToDictionary(u => u.Id, u => u.Name);

// ── Infra ───────────────────────────────────────────────────────────────────

using var loggerFactory = LoggerFactory.Create(b => b.AddSimpleConsole(o =>
{
    o.SingleLine = true;
    o.TimestampFormat = "HH:mm:ss.fff ";
}));
var log = loggerFactory.CreateLogger("bot");

var token = (await File.ReadAllTextAsync(tokenFile)).Trim();
var bot = new TelegramBotClient(token);
using var daemon = new DaemonClient(socketPath, loggerFactory.CreateLogger<DaemonClient>());
var staging = new Staging(runtimeDir, loggerFactory.CreateLogger<Staging>());

// in-memory bot-side session state, keyed by daemon's session id
var sessions = new Dictionary<string, BotSession>();
var sessionsLock = new Lock();

// gate: refuse to exit while an upload is in flight
var inFlight = 0;
var inFlightDrained = new SemaphoreSlim(1, 1);

// ── Bot commands ────────────────────────────────────────────────────────────

await bot.SetMyCommands([
    new() { Command = "scan", Description = "📷 Start a scan session" },
    new() { Command = "status", Description = "📊 Printer & scanner status" },
    new() { Command = "help",   Description = "❓ How to use this bot" },
]);
var mainKeyboard = new ReplyKeyboardMarkup(
    new[] { new KeyboardButton[] { "📷 Scan", "📊 Status" } })
{ ResizeKeyboard = true, IsPersistent = true };

log.LogInformation("bot starting, allowed users: {Users}, socket: {Sock}, staging: {Stg}",
    string.Join(", ", allowedUsers.Select(u => $"{u.Value}({u.Key})")),
    socketPath, runtimeDir);

// ── Cancellation / shutdown ─────────────────────────────────────────────────

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
AppDomain.CurrentDomain.ProcessExit += (_, _) => cts.Cancel();

// ── Background loops ────────────────────────────────────────────────────────

var sseLoop = Task.Run(() => RunSseLoopAsync(cts.Token));
var retryLoop = Task.Run(() => SweepStagingAsync(cts.Token));
var pollOffset = 0;

try
{
    while (!cts.IsCancellationRequested)
    {
        try
        {
            var updates = await bot.GetUpdates(pollOffset, timeout: 30, cancellationToken: cts.Token);
            foreach (var u in updates)
            {
                pollOffset = u.Id + 1;
                _ = Task.Run(() => HandleUpdateAsync(u, cts.Token));
            }
        }
        catch (OperationCanceledException) { break; }
        catch (Exception ex)
        {
            log.LogError(ex, "poll error");
            try { await Task.Delay(5000, cts.Token); } catch { break; }
        }
    }
}
finally
{
    log.LogInformation("draining in-flight uploads before exit");
    await inFlightDrained.WaitAsync();
    inFlightDrained.Release();
    try { await sseLoop; } catch { }
    try { await retryLoop; } catch { }
    log.LogInformation("clean exit");
}

// ────────────────────────────────────────────────────────────────────────────
// Update routing
// ────────────────────────────────────────────────────────────────────────────

async Task HandleUpdateAsync(Update update, CancellationToken ct)
{
    try
    {
        var userId = update.Message?.From?.Id ?? update.CallbackQuery?.From?.Id ?? 0;
        if (userId == 0) return;
        if (allowedUsers.Count > 0 && !allowedUsers.ContainsKey(userId))
        {
            log.LogWarning("unauthorized user {Id}", userId);
            return;
        }
        var name = allowedUsers.Count > 0 ? allowedUsers[userId] : "user";
        if (update.Message is { } msg)
            await HandleMessageAsync(name, msg, ct);
        else if (update.CallbackQuery is { } cb)
            await HandleCallbackAsync(name, cb, ct);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "update {Id} failed", update.Id);
    }
}

async Task HandleMessageAsync(string userName, Message msg, CancellationToken ct)
{
    if (msg.Document is { } doc) { await HandlePrintDocumentAsync(msg.Chat.Id, doc, ct); return; }
    if (msg.Photo is { Length: > 0 } ph) { await HandlePrintPhotoAsync(msg.Chat.Id, ph.Last(), ct); return; }

    var text = (msg.Text ?? "").Trim();
    var slash = text.Split(' ', '@')[0].ToLower();
    if (text.Equals("📷 Scan", StringComparison.OrdinalIgnoreCase) || slash == "/scan")
        await StartScanFlowAsync(msg.Chat.Id, userName, ct);
    else if (text.Equals("📊 Status", StringComparison.OrdinalIgnoreCase) || slash == "/status")
        await ShowStatusAsync(msg.Chat.Id, ct);
    else if (slash is "/help" or "/start")
        await bot.SendMessage(msg.Chat.Id, """
            🖨️ <b>PrintScan Bot</b>

            📄 Send a PDF or image to print it
            📷 /scan — start a scan session
            📊 /status — printer & scanner
            """, parseMode: ParseMode.Html, replyMarkup: mainKeyboard, cancellationToken: ct);
    else
        await bot.SendMessage(msg.Chat.Id, "Send a file to print, or tap 📷 Scan.",
            replyMarkup: mainKeyboard, cancellationToken: ct);
}

async Task HandleCallbackAsync(string userName, CallbackQuery cb, CancellationToken ct)
{
    var chatId = cb.Message!.Chat.Id;
    var msgId = cb.Message.Id;
    var data = cb.Data ?? "";
    await bot.AnswerCallbackQuery(cb.Id, cancellationToken: ct);

    if (data.StartsWith("open:"))
    {
        // format chosen → show DPI menu
        var fmt = data["open:".Length..];
        await bot.EditMessageText(chatId, msgId,
            $"📷 Format: <b>{fmt.ToUpperInvariant()}</b>. Choose resolution:",
            parseMode: ParseMode.Html,
            replyMarkup: ScanMenu.RenderDpi(fmt), cancellationToken: ct);
    }
    else if (data.StartsWith("dpi:"))
    {
        // format + dpi chosen → try to open daemon session
        var parts = data.Split(':');
        if (parts.Length != 3) return;
        var fmt = Enum.TryParse<ScanFormat>(parts[1], ignoreCase: true, out var f) ? f : ScanFormat.Jpeg;
        var dpi = int.TryParse(parts[2], out var d) ? d : ScanMenu.DefaultDpi;
        await TryOpenSessionAsync(chatId, msgId, userName, new ScanParams(dpi, fmt), takeover: false, ct);
    }
    else if (data.StartsWith("confirm_takeover:"))
    {
        var parts = data.Split(':');
        if (parts.Length != 4) return;
        var fmt = Enum.TryParse<ScanFormat>(parts[1], ignoreCase: true, out var f) ? f : ScanFormat.Jpeg;
        var dpi = int.TryParse(parts[2], out var d) ? d : ScanMenu.DefaultDpi;
        var answer = parts[3];
        if (answer == "yes")
            await TryOpenSessionAsync(chatId, msgId, userName, new ScanParams(dpi, fmt), takeover: true, ct);
        else
            await bot.EditMessageText(chatId, msgId, "Cancelled.", cancellationToken: ct);
    }
    else if (data.StartsWith("scan:"))
    {
        var sid = data["scan:".Length..];
        try
        {
            await daemon.RequestScanAsync(sid, ct);
        }
        catch (Exception ex)
        {
            await bot.SendMessage(chatId, $"❌ {ex.Message}", cancellationToken: ct);
        }
    }
    else if (data.StartsWith("end:"))
    {
        var sid = data["end:".Length..];
        await daemon.CloseSessionAsync(sid, ct);
    }
}

async Task StartScanFlowAsync(long chatId, string userName, CancellationToken ct)
{
    // single-step: ask format first. DPI follows after format selection.
    await bot.SendMessage(chatId, "📷 Pick a file format:",
        parseMode: ParseMode.Html,
        replyMarkup: ScanMenu.RenderFormat(), cancellationToken: ct);
}

async Task TryOpenSessionAsync(
    long chatId, int msgId, string userName, ScanParams parms,
    bool takeover, CancellationToken ct)
{
    // We first edit the callback message into "opening…", then use its id
    // as the session's status message id. Single message, no flicker.
    await bot.EditMessageText(chatId, msgId,
        "⏳ Opening session…", cancellationToken: ct);

    var req = new OpenSessionRequest(
        OwnerBot: "telegram",
        OwnerChatId: chatId,
        OwnerStatusMessageId: msgId,
        OwnerDisplayName: "@" + userName,
        Params: parms);

    DaemonClient.OpenResult outcome;
    SessionRecord? session;
    SessionConflict? conflict;
    try
    {
        (outcome, session, conflict) = await daemon.OpenSessionAsync(req, takeover, ct);
    }
    catch (Exception ex)
    {
        // Daemon rejected the request or is unreachable. Surface it —
        // otherwise the "Opening session…" message sits forever.
        log.LogError(ex, "OpenSessionAsync failed");
        await bot.EditMessageText(chatId, msgId,
            $"❌ Daemon error — couldn't open session.\n<code>{ex.Message}</code>",
            parseMode: ParseMode.Html, cancellationToken: ct);
        return;
    }
    if (outcome == DaemonClient.OpenResult.Conflict && conflict is not null)
    {
        // Two buttons with the chosen params baked into the callback data
        var kb = new InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton.WithCallbackData("Take over",
                    $"confirm_takeover:{parms.Format.ToString().ToLowerInvariant()}:{parms.Dpi}:yes"),
                InlineKeyboardButton.WithCallbackData("Cancel",
                    $"confirm_takeover:{parms.Format.ToString().ToLowerInvariant()}:{parms.Dpi}:no")
            ]
        ]);
        await bot.EditMessageText(chatId, msgId,
            $"🔒 {conflict.Current.OwnerDisplayName} has an active session " +
            $"({conflict.Current.ScanCount} scans). Take it over?",
            replyMarkup: kb, cancellationToken: ct);
        return;
    }
    if (session is null)
    {
        await bot.EditMessageText(chatId, msgId,
            "❌ Couldn't open session.", cancellationToken: ct);
        return;
    }
    // Register locally; SSE primer will confirm.
    lock (sessionsLock)
    {
        sessions[session.Id] = new BotSession
        {
            DaemonSessionId = session.Id,
            ChatId = chatId,
            StatusMessageId = msgId,
            Params = session.Params,
            ExpiresAt = session.ExpiresAt,
            ScanCount = session.ScanCount,
            FirstScanPending = true,
        };
    }
    await RerenderAsync(session.Id, ct);
}

// ────────────────────────────────────────────────────────────────────────────
// Print path (as before)
// ────────────────────────────────────────────────────────────────────────────

async Task HandlePrintDocumentAsync(long chatId, Document doc, CancellationToken ct)
{
    var status = await bot.SendMessage(chatId,
        $"🖨️ Printing <code>{doc.FileName}</code>…",
        parseMode: ParseMode.Html, cancellationToken: ct);
    try
    {
        using var ms = new MemoryStream();
        await bot.GetInfoAndDownloadFile(doc.FileId, ms, ct);
        ms.Position = 0;
        using var content = new MultipartFormDataContent();
        var file = new StreamContent(ms);
        file.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        content.Add(file, "file", doc.FileName ?? "document");
        using var http = new HttpClient(new SocketsHttpHandler
        {
            ConnectCallback = async (_, innerCt) =>
            {
                var sock = new System.Net.Sockets.Socket(
                    System.Net.Sockets.AddressFamily.Unix,
                    System.Net.Sockets.SocketType.Stream,
                    System.Net.Sockets.ProtocolType.Unspecified);
                await sock.ConnectAsync(new System.Net.Sockets.UnixDomainSocketEndPoint(socketPath), innerCt);
                return new System.Net.Sockets.NetworkStream(sock, ownsSocket: true);
            }
        }) { BaseAddress = new Uri("http://localhost") };
        var resp = await http.PostAsync("/print", content, ct);
        await bot.EditMessageText(chatId, status.Id,
            resp.IsSuccessStatusCode ? $"✅ Printed <code>{doc.FileName}</code>"
                                     : $"❌ Print failed: {resp.StatusCode}",
            parseMode: ParseMode.Html, cancellationToken: ct);
    }
    catch (Exception ex)
    {
        await bot.EditMessageText(chatId, status.Id, $"❌ Print error: {ex.Message}", cancellationToken: ct);
    }
}

async Task HandlePrintPhotoAsync(long chatId, PhotoSize photo, CancellationToken ct)
{
    // Same pipeline as document path with a fixed filename/content-type.
    var fake = new Document
    {
        FileId = photo.FileId,
        FileName = "photo.jpg"
    };
    await HandlePrintDocumentAsync(chatId, fake, ct);
}

async Task ShowStatusAsync(long chatId, CancellationToken ct)
{
    var st = await daemon.GetStatusAsync(ct);
    if (st is null)
    {
        await bot.SendMessage(chatId, "📊 Daemon unreachable", cancellationToken: ct);
        return;
    }
    await bot.SendMessage(chatId, $"""
        📊 <b>Status</b>

        🖨️ Printer: {(st.Printer.Online ? "✅ online" : "⚠️ offline")}
        📷 Scanner: {(st.Scanner.Online ? "✅ online" : "⚠️ offline")}
        """, parseMode: ParseMode.Html, cancellationToken: ct);
}

// ────────────────────────────────────────────────────────────────────────────
// SSE consumer
// ────────────────────────────────────────────────────────────────────────────

async Task RunSseLoopAsync(CancellationToken ct)
{
    await foreach (var ev in daemon.SubscribeAsync(ct))
    {
        try { await HandleEventAsync(ev, ct); }
        catch (Exception ex) { log.LogError(ex, "event handler failed: {Type}", ev.Type); }
    }
}

async Task HandleEventAsync(SessionEvent ev, CancellationToken ct)
{
    switch (ev.Type)
    {
        case SessionEventType.SessionOpened when ev.Session is not null:
        {
            var s = ev.Session;
            lock (sessionsLock)
            {
                if (!sessions.ContainsKey(s.Id) && s.OwnerBot == "telegram")
                {
                    // Reconstruct from primer (daemon restart) — we don't
                    // own this in memory, rebuild it.
                    sessions[s.Id] = new BotSession
                    {
                        DaemonSessionId = s.Id,
                        ChatId = s.OwnerChatId,
                        StatusMessageId = s.OwnerStatusMessageId,
                        Params = s.Params,
                        ExpiresAt = s.ExpiresAt,
                        ScanCount = s.ScanCount,
                    };
                }
                else if (sessions.TryGetValue(s.Id, out var bs))
                {
                    bs.ExpiresAt = s.ExpiresAt;
                    bs.ScanCount = s.ScanCount;
                }
            }
            await RerenderAsync(s.Id, ct);
            break;
        }
        case SessionEventType.SessionExtended when ev.Session is not null:
        {
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.Session.Id, out var bs))
                    bs.ExpiresAt = ev.Session.ExpiresAt;
            }
            await RerenderAsync(ev.Session.Id, ct);
            break;
        }
        case SessionEventType.SessionScanning when ev.SessionId is not null:
        {
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.SessionId, out var bs))
                    bs.Scanning = true;
            }
            await RerenderAsync(ev.SessionId, ct);
            break;
        }
        case SessionEventType.SessionImageReady when ev.SessionId is not null && ev.Seq is int seq:
        {
            await DeliverImageAsync(ev.SessionId, seq, ev.ContentType ?? "image/jpeg",
                ev.FileName ?? $"scan-{seq}.jpg", ct);
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.SessionId, out var bs))
                {
                    bs.Scanning = false;
                    bs.ScanCount = seq;
                    bs.LastUploadedSeq = seq;
                }
            }
            await RerenderAsync(ev.SessionId, ct);
            break;
        }
        case SessionEventType.SessionScanFailed when ev.SessionId is not null:
        {
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.SessionId, out var bs))
                {
                    bs.Scanning = false;
                }
            }
            if (sessions.TryGetValue(ev.SessionId, out var s0))
                await bot.SendMessage(s0.ChatId,
                    $"❌ Scan failed: {ev.Error}", cancellationToken: ct);
            await RerenderAsync(ev.SessionId, ct);
            break;
        }
        case SessionEventType.ScannerOnline:
        {
            List<(string sid, bool auto)> toNotify;
            lock (sessionsLock)
            {
                foreach (var s in sessions.Values) s.ScannerOnline = true;
                toNotify = sessions.Values.Select(s => (s.DaemonSessionId, s.FirstScanPending)).ToList();
                foreach (var s in sessions.Values) s.FirstScanPending = false;
            }
            foreach (var (sid, auto) in toNotify)
            {
                await RerenderAsync(sid, ct);
                if (auto)
                {
                    try { await daemon.RequestScanAsync(sid, ct); }
                    catch (Exception ex) { log.LogWarning("auto-scan failed: {Err}", ex.Message); }
                }
            }
            break;
        }
        case SessionEventType.ScannerOffline:
        {
            List<string> sids;
            lock (sessionsLock)
            {
                foreach (var s in sessions.Values) s.ScannerOnline = false;
                sids = [.. sessions.Keys];
            }
            foreach (var sid in sids) await RerenderAsync(sid, ct);
            break;
        }
        case SessionEventType.ScannerButton:
        {
            // future: button poller. Translate to a scan request for the
            // active session on this bot.
            List<string> sids;
            lock (sessionsLock) { sids = [.. sessions.Keys]; }
            foreach (var sid in sids)
            {
                try { await daemon.RequestScanAsync(sid, ct); }
                catch (Exception ex) { log.LogWarning("button scan failed: {Err}", ex.Message); }
            }
            break;
        }
        case SessionEventType.SessionTerminated when ev.SessionId is not null:
        {
            BotSession? s;
            lock (sessionsLock)
            {
                sessions.TryGetValue(ev.SessionId, out s);
                sessions.Remove(ev.SessionId);
            }
            if (s is not null)
            {
                try
                {
                    await bot.EditMessageText(s.ChatId, s.StatusMessageId,
                        StatusMessage.RenderTerminated(s, ev.Reason ?? SessionTerminationReason.Closed, ev.NewOwner),
                        parseMode: ParseMode.Html, replyMarkup: null,
                        cancellationToken: ct);
                }
                catch { /* message may have been deleted */ }
                staging.WipeSession(ev.SessionId);
            }
            break;
        }
    }
}

async Task RerenderAsync(string sessionId, CancellationToken ct)
{
    BotSession? s;
    lock (sessionsLock) { sessions.TryGetValue(sessionId, out s); }
    if (s is null) return;
    var (html, kb) = StatusMessage.Render(s);
    try
    {
        await bot.EditMessageText(s.ChatId, s.StatusMessageId, html,
            parseMode: ParseMode.Html, replyMarkup: kb, cancellationToken: ct);
    }
    catch (Exception ex)
    {
        // Most common: "message is not modified" — ignore.
        if (!ex.Message.Contains("not modified", StringComparison.OrdinalIgnoreCase))
            log.LogDebug("edit failed: {Err}", ex.Message);
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Image delivery: fetch from daemon, stage to disk, upload to TG, unstage.
// ────────────────────────────────────────────────────────────────────────────

async Task DeliverImageAsync(string sessionId, int seq, string contentType,
    string fileName, CancellationToken ct)
{
    Interlocked.Increment(ref inFlight);
    try { await inFlightDrained.WaitAsync(ct); } catch { }
    try
    {
        BotSession? bs;
        lock (sessionsLock) { sessions.TryGetValue(sessionId, out bs); }
        if (bs is null) return;

        var ext = Path.GetExtension(fileName).TrimStart('.');
        string path;
        await using (var stream = await daemon.FetchImageAsync(sessionId, seq, ct))
        {
            path = await staging.StageAsync(sessionId, seq, ext, stream, ct);
        }
        staging.RecordManifest(sessionId, seq, new StagedEntry(
            ChatId: bs.ChatId, FileName: fileName, ContentType: contentType,
            Caption: $"📷 {bs.Params.Dpi} dpi · scan #{seq}"));

        await UploadStagedAsync(sessionId, seq, path, bs.ChatId, fileName,
            $"📷 {bs.Params.Dpi} dpi · scan #{seq}", ct);
    }
    finally
    {
        if (Interlocked.Decrement(ref inFlight) == 0)
            inFlightDrained.Release();
    }
}

async Task UploadStagedAsync(
    string sessionId, int seq, string path, long chatId,
    string fileName, string caption, CancellationToken ct)
{
    try
    {
        await using var stream = File.OpenRead(path);
        await bot.SendDocument(chatId, new InputFileStream(stream, fileName),
            caption: caption, cancellationToken: ct);
        staging.Remove(sessionId, seq);
        log.LogInformation("delivered {Session}#{Seq} → {Chat}", sessionId, seq, chatId);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "upload of {Session}#{Seq} failed, staging kept for retry", sessionId, seq);
    }
}

async Task SweepStagingAsync(CancellationToken ct)
{
    // Called once at startup: any scans in the staging dir are unfinished
    // uploads from a previous bot process. Retry them in order.
    try { await Task.Delay(2000, ct); } catch { return; }
    foreach (var (sessionId, seq, entry, path) in staging.EnumeratePending())
    {
        if (ct.IsCancellationRequested) return;
        log.LogInformation("retry upload {Session}#{Seq} from staging", sessionId, seq);
        await UploadStagedAsync(sessionId, seq, path, entry.ChatId,
            entry.FileName, entry.Caption, ct);
    }
}

// ────────────────────────────────────────────────────────────────────────────
record AllowedUser(long Id, string Name);
