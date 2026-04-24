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

// ── Cancellation / shutdown ─────────────────────────────────────────────────

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
AppDomain.CurrentDomain.ProcessExit += (_, _) => cts.Cancel();

// ── Bot identity + commands ─────────────────────────────────────────────────

// The bot runs on a box that can see network dark periods at any time —
// from "systemd started us before resolved is live" at boot to "Wi-Fi
// dropped for 30s" during the day. A single HttpRequestException from
// the Telegram client must never crash the process. Wrap any TG call we
// make before the main poll loop (which has its own catch+sleep) in a
// retry with capped exponential back-off.
var me = await Retry.Transient(
    () => bot.GetMe(), "bot.GetMe()", log, cts.Token);
var botUsername = me.Username
    ?? throw new Exception("bot.GetMe() returned no username — token may be wrong");
log.LogInformation("bot identity: @{Username} (id={Id})", botUsername, me.Id);

await Retry.Transient(
    () => bot.SetMyCommands([
        new() { Command = "scanner", Description = "📷 Open scanner session" },
        new() { Command = "status", Description = "📊 Printer & scanner status" },
        new() { Command = "help",   Description = "❓ How to use this bot" },
    ]),
    "bot.SetMyCommands()", log, cts.Token);

var mainKeyboard = new ReplyKeyboardMarkup(
    new[] { new KeyboardButton[] { "📷 Scanner", "📊 Status" } })
{ ResizeKeyboard = true, IsPersistent = true };

log.LogInformation("bot starting, allowed users: {Users}, socket: {Sock}, staging: {Stg}",
    string.Join(", ", allowedUsers.Select(u => $"{u.Value}({u.Key})")),
    socketPath, runtimeDir);

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

    // Deep-link payloads arrive as "/start <payload>". Our hyperlinks
    // in session bodies use the payload "end_<sid>" to close a session
    // via link-tap. Parse first so we recognise actionable payloads
    // before the generic /start help handler below.
    if (slash == "/start")
    {
        var parts = text.Split(' ', 2);
        var payload = parts.Length > 1 ? parts[1].Trim() : "";
        if (payload.StartsWith("end_"))
        {
            var sid = payload["end_".Length..];
            try
            {
                await daemon.CloseSessionAsync(sid, ct);
                // Clean up the user's /start message so the chat stays
                // tidy — the session-ended render in the status message
                // is the feedback.
                try { await bot.DeleteMessage(msg.Chat.Id, msg.Id, ct); }
                catch (Exception ex) { log.LogDebug("delete of /start end_ msg failed: {Err}", ex.Message); }
            }
            catch (Exception ex)
            {
                log.LogWarning(ex, "CloseSessionAsync({Sid}) via /start end_ failed", sid);
            }
            return;
        }
        // fall through to standard /start help below
    }

    if (text.Equals("📷 Scanner", StringComparison.OrdinalIgnoreCase)
        || slash is "/scanner" or "/scan")
        await OpenScannerSessionAsync(msg.Chat.Id, userName, ct);
    else if (text.Equals("📊 Status", StringComparison.OrdinalIgnoreCase) || slash == "/status")
        await ShowStatusAsync(msg.Chat.Id, ct);
    else if (slash is "/help" or "/start")
        await bot.SendMessage(msg.Chat.Id, """
            🖨️ <b>PrintScan Bot</b>

            📄 Send a PDF or image to print it
            📷 /scanner — open scanner session
            📊 /status — printer &amp; scanner
            """, parseMode: ParseMode.Html, replyMarkup: mainKeyboard, cancellationToken: ct);
    else
        await bot.SendMessage(msg.Chat.Id, "Send a file to print, or tap 📷 Scanner.",
            replyMarkup: mainKeyboard, cancellationToken: ct);
}

async Task HandleCallbackAsync(string userName, CallbackQuery cb, CancellationToken ct)
{
    var chatId = cb.Message!.Chat.Id;
    var msgId = cb.Message.Id;
    var data = cb.Data ?? "";
    await bot.AnswerCallbackQuery(cb.Id, cancellationToken: ct);

    // Format: pick:<fmt|dpi>:<sessionId>  — open a picker view
    //         set:<fmt|dpi>:<sessionId>:<value>  — apply change + back to main
    //         cancel:<sessionId>  — back to main (abandon picker)
    //         scan:<sessionId>  — trigger a scan
    //         end:<sessionId>  — close the session
    //         takeover:yes|no  — response to takeover confirmation
    if (data.StartsWith("pick:"))
    {
        var parts = data.Split(':');
        if (parts.Length != 3) return;
        var what = parts[1];
        var sid = parts[2];
        var view = what switch
        {
            "fmt" => PickerView.Format,
            "dpi" => PickerView.Dpi,
            _     => PickerView.Main,
        };
        await RerenderAsync(sid, ct, view);
    }
    else if (data.StartsWith("set:") || data.StartsWith("toggle:"))
    {
        // set:fmt:<sid>:jpeg        (legacy, used by dpi)
        // set:dpi:<sid>:300
        // toggle:fmt:<sid>:jpeg     (checkbox — XORs the bit; refuses to
        //                            unset the last set bit)
        var parts = data.Split(':');
        if (parts.Length != 4) return;
        var verb = parts[0];
        var what = parts[1];
        var sid = parts[2];
        var value = parts[3];

        BotSession? s;
        lock (sessionsLock) { sessions.TryGetValue(sid, out s); }
        if (s is null) return;

        static ScanFormat? ParseFormat(string v) => v switch
        {
            "jpeg" or "jpg"       => ScanFormat.Jpeg,
            "png"                 => ScanFormat.Png,
            "webp-lossy" or "webp" => ScanFormat.WebpLossy,
            "webp-lossless" or "webpl" => ScanFormat.WebpLossless,
            _ => null,
        };

        // Toggle with a "never leave zero formats selected" guard —
        // daemon falls back to Jpeg on empty mask but we prefer the
        // UI to make refusals explicit rather than silently force a
        // format the user had just unchecked.
        static ScanFormat Toggle(ScanFormat cur, ScanFormat bit) =>
            ((cur ^ bit) == ScanFormat.None) ? cur : (cur ^ bit);

        var newParams = (verb, what) switch
        {
            ("toggle", "fmt") when ParseFormat(value) is ScanFormat f =>
                s.Params with { Format = Toggle(s.Params.Format, f) },
            ("set", "dpi") when int.TryParse(value, out var d) =>
                s.Params with { Dpi = d },
            _ => s.Params,
        };
        try
        {
            await daemon.PatchSessionParamsAsync(sid, newParams, ct);
        }
        catch (Exception ex)
        {
            log.LogWarning("PATCH session params failed: {Err}", ex.Message);
        }
        // SessionOpened event from daemon will pick up new params and
        // re-render; render now too so the UI doesn't lag the SSE roundtrip.
        lock (sessionsLock)
        {
            if (sessions.TryGetValue(sid, out var bs)) bs.Params = newParams;
        }
        // Stay on the format picker when toggling so users can flip
        // multiple boxes in a row without leaving the picker view.
        var stayView = (verb, what) switch
        {
            ("toggle", "fmt") => PickerView.Format,
            _ => PickerView.Main,
        };
        await RerenderAsync(sid, ct, stayView);
    }
    else if (data.StartsWith("cancel:"))
    {
        var sid = data["cancel:".Length..];
        await RerenderAsync(sid, ct, PickerView.Main);
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
    else if (data == "takeover:yes")
    {
        await OpenScannerSessionAsync(chatId, userName, ct, takeover: true, reuseMsgId: msgId);
    }
    else if (data == "takeover:no")
    {
        await bot.EditMessageText(chatId, msgId, "Cancelled.", cancellationToken: ct);
    }
}

async Task OpenScannerSessionAsync(
    long chatId, string userName, CancellationToken ct,
    bool takeover = false, int? reuseMsgId = null)
{
    // Send (or reuse) the status message FIRST — we need its id for the
    // session record's OwnerStatusMessageId, which SSE re-renders then
    // edit in place.
    int msgId;
    if (reuseMsgId is int rid)
    {
        msgId = rid;
        await bot.EditMessageText(chatId, msgId, "⏳ Opening session…",
            cancellationToken: ct);
    }
    else
    {
        var placeholder = await bot.SendMessage(chatId, "⏳ Opening session…",
            cancellationToken: ct);
        msgId = placeholder.Id;
    }

    var req = new OpenSessionRequest(
        OwnerBot: "telegram",
        OwnerChatId: chatId,
        OwnerStatusMessageId: msgId,
        OwnerDisplayName: "@" + userName,
        Params: StatusMessage.Defaults());

    DaemonClient.OpenResult outcome;
    SessionRecord? session;
    SessionConflict? conflict;
    try
    {
        (outcome, session, conflict) = await daemon.OpenSessionAsync(req, takeover, ct);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "OpenSessionAsync failed");
        await bot.EditMessageText(chatId, msgId,
            $"❌ Daemon error — couldn't open session.\n<code>{ex.Message}</code>",
            parseMode: ParseMode.Html, cancellationToken: ct);
        return;
    }
    if (outcome == DaemonClient.OpenResult.Conflict && conflict is not null)
    {
        var kb = new InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton.WithCallbackData("Take over", "takeover:yes"),
                InlineKeyboardButton.WithCallbackData("Cancel",    "takeover:no"),
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
    // Every user-visible top-level reply re-asserts mainKeyboard. Not
    // passing replyMarkup doesn't *remove* a persistent reply keyboard,
    // but some Telegram clients stop showing it after a stretch of
    // replies without one. Cheapest reliable way to keep the keyboard
    // pinned is just to include it on every non-inline reply.
    var st = await daemon.GetStatusAsync(ct);
    if (st is null)
    {
        await bot.SendMessage(chatId, "📊 Daemon unreachable",
            replyMarkup: mainKeyboard, cancellationToken: ct);
        return;
    }
    await bot.SendMessage(chatId, $"""
        📊 <b>Status</b>

        🖨️ Printer: {(st.Printer.Online ? "✅ online" : "⚠️ offline")}
        📷 Scanner: {(st.Scanner.Online ? "✅ online" : "⚠️ offline")}
        """, parseMode: ParseMode.Html, replyMarkup: mainKeyboard, cancellationToken: ct);
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
                    // SessionOpened is also re-emitted on PATCH-params
                    // so pick up param changes here.
                    bs.ExpiresAt = s.ExpiresAt;
                    bs.ScanCount = s.ScanCount;
                    bs.Params    = s.Params;
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
                {
                    bs.Scanning = true;
                    bs.ScanProgress = 0;
                    // QueuedCount (if present) = scans queued BEHIND the
                    // scan that's just starting. Sync from daemon truth;
                    // fall back to 0 on older daemons that don't emit it.
                    bs.QueuedScans = ev.QueuedCount ?? 0;
                }
            }
            await RerenderAsync(ev.SessionId, ct);
            break;
        }
        case SessionEventType.SessionScanQueued when ev.SessionId is not null:
        {
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.SessionId, out var bs))
                    bs.QueuedScans = ev.QueuedCount ?? bs.QueuedScans;
            }
            await RerenderAsync(ev.SessionId, ct);
            break;
        }
        case SessionEventType.SessionScanProgress when ev.SessionId is not null && ev.PercentDone is int pct:
        {
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.SessionId, out var bs))
                    bs.ScanProgress = pct;
            }
            // Every 5% tick is ~20 edits per scan, ~2-4 edits/sec —
            // comfortably under Telegram's per-chat rate limit.
            await RerenderAsync(ev.SessionId, ct);
            break;
        }
        case SessionEventType.SessionImageReady when ev.SessionId is not null && ev.Seq is int seq:
        {
            // Daemon fires one image-ready event per variant (one per
            // selected format bit). Deliver this specific variant now;
            // flip Scanning=false and bump ScanCount only once the LAST
            // variant has delivered, so the status bar keeps showing
            // "scanning…" while additional formats are still streaming.
            var variant = ev.Variant ?? 0;
            var isLastVariant = ev.VariantCount is int vc ? variant == vc - 1 : true;
            await DeliverImageAsync(ev.SessionId, seq, variant,
                ev.ContentType ?? "image/jpeg",
                ev.FileName ?? $"scan-{seq}.jpg", ct);
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.SessionId, out var bs) && isLastVariant)
                {
                    bs.ScanCount = seq;
                    bs.LastUploadedSeq = seq;
                    // If there's a queued scan about to start, keep
                    // Scanning=true so the button doesn't flicker to
                    // idle between SessionImageReady(last-variant) and
                    // the upcoming SessionScanning(next-seq). Progress
                    // gets reset when that next SessionScanning fires.
                    if (bs.QueuedScans == 0) bs.Scanning = false;
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
            // New UX: never auto-scan on scanner-online. User must tap
            // [📷 Scan] in the session (or press the physical button —
            // hardware-TBD) to confirm intent. We just re-render so the
            // status reflects scanner readiness.
            List<string> sids;
            lock (sessionsLock)
            {
                foreach (var s in sessions.Values) s.ScannerOnline = true;
                sids = [.. sessions.Keys];
            }
            foreach (var sid in sids) await RerenderAsync(sid, ct);
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

async Task RerenderAsync(string sessionId, CancellationToken ct,
    PickerView view = PickerView.Main)
{
    BotSession? s;
    lock (sessionsLock) { sessions.TryGetValue(sessionId, out s); }
    if (s is null) return;
    var (html, kb) = StatusMessage.Render(s, botUsername, view);
    try
    {
        await bot.EditMessageText(s.ChatId, s.StatusMessageId, html,
            parseMode: ParseMode.Html, replyMarkup: kb,
            // Deep-link "end" in the body would otherwise render as a
            // Telegram link-preview card ("t.me/yourbot"). Disable.
            linkPreviewOptions: new() { IsDisabled = true },
            cancellationToken: ct);
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

async Task DeliverImageAsync(string sessionId, int seq, int variant, string contentType,
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
        // Stage key uses seq AND variant so distinct formats of the same
        // scan don't collide (a WebP-lossy and JPG of scan #3 are both
        // legitimately "scan 3, variant N").
        var stageSeq = seq * 100 + variant;
        string path;
        await using (var stream = await daemon.FetchImageAsync(sessionId, seq, variant, ct))
        {
            path = await staging.StageAsync(sessionId, stageSeq, ext, stream, ct);
        }
        staging.RecordManifest(sessionId, stageSeq, new StagedEntry(
            ChatId: bs.ChatId, FileName: fileName, ContentType: contentType,
            Caption: $"📷 {bs.Params.Dpi} dpi · scan #{seq}"));

        await UploadStagedAsync(sessionId, stageSeq, path, bs.ChatId, fileName,
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
        // disableContentTypeDetection=true prevents Telegram from
        // rendering e.g. a small lossy WebP as an inline photo preview
        // while larger files land in the document listing — we want a
        // consistent "file attachment" look across all formats so users
        // can compare sizes at a glance. The stored bytes are identical
        // either way; this only affects the client's rendering choice.
        await bot.SendDocument(chatId, new InputFileStream(stream, fileName),
            caption: caption, disableContentTypeDetection: true,
            cancellationToken: ct);
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
// Resilience helper: re-run a TG call on transient network failures with
// capped exponential back-off. Used only for startup-critical calls
// (GetMe, SetMyCommands) — the main long-poll loop has its own catch +
// 5s-delay retry path. We loop forever (until the passed CancellationToken
// is tripped); if the box has no connectivity at all, the service just
// sits here instead of crashing and being marked failed.
//
// Lives in a static class (not a local function) because top-level
// statements compile to one scope and don't permit function overloads;
// we want both Func<Task<T>> and Func<Task> signatures.
static class Retry
{
    public static async Task<T> Transient<T>(
        Func<Task<T>> op, string what, ILogger log, CancellationToken ct)
    {
        var attempt = 0;
        while (true)
        {
            try { return await op(); }
            catch (Exception ex) when (!ct.IsCancellationRequested && IsTransient(ex))
            {
                attempt++;
                var delay = TimeSpan.FromSeconds(Math.Min(30, 1 << Math.Min(attempt, 5)));
                log.LogWarning(
                    "{What} attempt #{N} transient error: {Msg} — retry in {Sec}s",
                    what, attempt, ex.Message, (int)delay.TotalSeconds);
                await Task.Delay(delay, ct);
            }
        }
    }

    public static Task Transient(
        Func<Task> op, string what, ILogger log, CancellationToken ct) =>
        Transient<object?>(async () => { await op(); return null; }, what, log, ct);

    // Any network-adjacent failure counts as transient. DNS name-not-known
    // and socket errors bubble up via TG's RequestException (inner is
    // HttpRequestException/SocketException). TaskCanceledException also
    // appears on HTTP timeouts. Operator-signal cancellations are handled
    // by the ct.IsCancellationRequested check in the outer `when` clause.
    static bool IsTransient(Exception ex) =>
        ex is System.Net.Http.HttpRequestException ||
        ex is System.Net.Sockets.SocketException ||
        ex is TaskCanceledException ||
        (ex.InnerException is Exception inner && IsTransient(inner));
}

record AllowedUser(long Id, string Name);
