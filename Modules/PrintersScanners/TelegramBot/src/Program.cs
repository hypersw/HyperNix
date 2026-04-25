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
var pipeline = new ImagePipeline(loggerFactory.CreateLogger<ImagePipeline>());

// Renderer is optional. When the env var is unset we run without it
// and the bot's classifier rejects doc/docx/odt with a "send a PDF"
// hint instead of trying to convert.
var rendererSocket = Environment.GetEnvironmentVariable("PRINTSCAN_RENDERER_SOCKET");
using var renderer = new RendererClient(
    rendererSocket, loggerFactory.CreateLogger<RendererClient>());

// in-memory bot-side session state, keyed by daemon's session id
var sessions = new Dictionary<string, BotSession>();
var sessionsLock = new Lock();

// Per-chat printer-session state. Lives entirely on the bot (printing
// has no exclusive-resource model the way scanning does — multiple
// users can submit jobs to CUPS in parallel) so there's no daemon-side
// session lifecycle to mirror. Lost on bot restart; user re-sends.
var printSessions = new Dictionary<long, BotPrintSession>();
var printSessionsLock = new Lock();

// In-flight scan-delivery counter. We don't gate concurrency on it
// (Telegram tolerates parallel uploads to different chats fine) — it
// only exists so graceful shutdown can wait until pending scans have
// finished re-encoding and uploading before the process exits.
var inFlightCount = 0;

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
        new() { Command = "printer", Description = "🖨 Open printer session" },
        new() { Command = "status",  Description = "📊 Printer & scanner status" },
        new() { Command = "help",    Description = "❓ How to use this bot" },
    ]),
    "bot.SetMyCommands()", log, cts.Token);

// "…" suffix on Scanner/Printer to convey "this opens a UI" — same
// connotation as the Windows menu-item ellipsis. Status doesn't get
// one because it's a one-shot status read with nothing to interact
// with after.
var mainKeyboard = new ReplyKeyboardMarkup(
    new[] { new KeyboardButton[] { "📷 Scanner…", "🖨 Printer…", "📊 Status" } })
{ ResizeKeyboard = true, IsPersistent = true };

log.LogInformation("bot starting, allowed users: {Users}, socket: {Sock}",
    string.Join(", ", allowedUsers.Select(u => $"{u.Value}({u.Key})")),
    socketPath);

// ── Background loops ────────────────────────────────────────────────────────

var sseLoop = Task.Run(() => RunSseLoopAsync(cts.Token));
var printerPollLoop = Task.Run(() => PollPrinterStatusAsync(cts.Token));
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
    var drainStart = DateTime.UtcNow;
    while (Volatile.Read(ref inFlightCount) > 0 &&
           DateTime.UtcNow - drainStart < TimeSpan.FromSeconds(30))
    {
        try { await Task.Delay(100); } catch { break; }
    }
    try { await sseLoop; } catch { }
    try { await printerPollLoop; } catch { }
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
    // File arrivals route into the printer session for confirmation
    // — we never start a print job from an incoming file alone.
    // Auth has already been checked by HandleUpdateAsync above; if
    // we're here at all the user is allowed.
    if (msg.Document is { } doc)
    {
        await StageDocumentForPrintAsync(msg.Chat.Id, doc, ct);
        return;
    }
    if (msg.Photo is { Length: > 0 } ph)
    {
        await StagePhotoForPrintAsync(msg.Chat.Id, ph.Last(), ct);
        return;
    }

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
        if (payload == "printend")
        {
            await ClosePrinterSessionAsync(msg.Chat.Id, ct);
            try { await bot.DeleteMessage(msg.Chat.Id, msg.Id, ct); }
            catch (Exception ex) { log.LogDebug("delete of /start printend msg failed: {Err}", ex.Message); }
            return;
        }
        // fall through to standard /start help below
    }

    // Accept both old and new label spellings (with/without the "…")
    // so users with stale persistent reply keyboards keep working.
    if (text is "📷 Scanner" or "📷 Scanner…"
        || slash is "/scanner" or "/scan")
        await OpenScannerSessionAsync(msg.Chat.Id, userName, ct);
    else if (text is "🖨 Printer" or "🖨 Printer…"
                  or "🖨️ Printer" or "🖨️ Printer…"
             || slash is "/printer" or "/print")
        await OpenPrinterSessionAsync(msg.Chat.Id, ct);
    else if (text == "📊 Status" || slash == "/status")
        await ShowStatusAsync(msg.Chat.Id, ct);
    else if (slash is "/help" or "/start")
        await bot.SendMessage(msg.Chat.Id, """
            🖨️ <b>PrintScan Bot</b>

            📷 /scanner — open scanner session
            🖨 /printer — open printer session, then send a file to print
            📊 /status — printer &amp; scanner

            Files (PDF, PostScript, images) you send while a printer
            session is open get staged for confirmation before
            printing — nothing prints unless you tap ✅ Print.
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

    // Printer-session callbacks have their own "print:" prefix so
    // they don't collide with scanner pick:/set:/cancel:/scan:/end:.
    if (data.StartsWith("print:"))
    {
        await HandlePrintCallbackAsync(chatId, data, ct);
        return;
    }

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
        // we prefer the UI to make refusals explicit rather than
        // silently fall back to a format the user had just unchecked.
        static ScanFormat Toggle(ScanFormat cur, ScanFormat bit) =>
            ((cur ^ bit) == ScanFormat.None) ? cur : (cur ^ bit);

        // Format selection is a bot-only concern — daemon doesn't
        // operate on formats. We persist it via the daemon's opaque
        // session-metadata bag so the choice survives bot restarts;
        // dpi flows through ScanParams as before because the daemon
        // does need it to pass to scanimage.
        if (verb == "toggle" && what == "fmt" && ParseFormat(value) is ScanFormat f)
        {
            var newFormat = Toggle(s.Format, f);
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(sid, out var bs)) bs.Format = newFormat;
            }
            try
            {
                await daemon.PutMetadataAsync(sid,
                    new() { [MetadataKeys.Format] = ((int)newFormat).ToString() }, ct);
            }
            catch (Exception ex)
            {
                log.LogWarning("PUT metadata failed: {Err}", ex.Message);
            }
            // Stay on the format picker so users can flip multiple
            // boxes in a row without leaving the picker view.
            await RerenderAsync(sid, ct, PickerView.Format);
        }
        else if (verb == "set" && what == "dpi" && int.TryParse(value, out var d))
        {
            var newParams = s.Params with { Dpi = d };
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(sid, out var bs)) bs.Params = newParams;
            }
            try
            {
                await daemon.PatchSessionParamsAsync(sid, newParams, ct);
            }
            catch (Exception ex)
            {
                log.LogWarning("PATCH session params failed: {Err}", ex.Message);
            }
            await RerenderAsync(sid, ct, PickerView.Main);
        }
        else
        {
            await RerenderAsync(sid, ct, PickerView.Main);
        }
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
        Params: StatusMessage.DefaultParams(),
        Metadata: new() { [MetadataKeys.Format] = ((int)StatusMessage.DefaultFormat).ToString() });

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
        // Self-conflict: the "conflicting" session is this user's own.
        // Offering to "take over your own session" is nonsense; send a
        // reply that points at the existing session message instead.
        // Telegram renders a reply-chip the user taps to jump to the
        // referenced message — solves the "session scrolled far back
        // after many scans" problem without us needing to re-render
        // or move the session header.
        if (conflict.Current.OwnerChatId == chatId)
        {
            await bot.DeleteMessage(chatId, msgId, ct);   // placeholder isn't needed
            try
            {
                await bot.SendMessage(chatId,
                    "📷 You already have an active scanner session — tap the reply above to jump to it.",
                    replyParameters: new() { MessageId = conflict.Current.OwnerStatusMessageId },
                    cancellationToken: ct);
            }
            catch (Exception ex)
            {
                // If the original session message was deleted, replying
                // fails; fall back to a plain message.
                log.LogDebug("self-conflict reply-to failed, falling back: {Err}", ex.Message);
                await bot.SendMessage(chatId,
                    "📷 You already have an active scanner session.",
                    cancellationToken: ct);
            }
            return;
        }
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
            Format = ParseFormatFromMetadata(session.Metadata),
            ExpiresAt = session.ExpiresAt,
            ScanCount = session.ScanCount,
        };
    }
    await RerenderAsync(session.Id, ct);
}

// Decode the bot's format selection out of the daemon's opaque metadata
// bag. Falls back to the default if the key is missing (fresh session
// from another client) or unparseable.
static ScanFormat ParseFormatFromMetadata(Dictionary<string, string>? meta)
{
    if (meta is null || !meta.TryGetValue(MetadataKeys.Format, out var s))
        return StatusMessage.DefaultFormat;
    if (int.TryParse(s, out var n) && Enum.IsDefined(typeof(ScanFormat), n))
        return (ScanFormat)n;
    return StatusMessage.DefaultFormat;
}

// ────────────────────────────────────────────────────────────────────────────
// Print path (as before)
// ────────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────────
// Printer session: per-chat in-bot state. Files arrive → staged →
// confirmation UI → daemon /print (currently a stub). Auth has already
// been enforced upstream by HandleUpdateAsync's allowedUsers check, so
// every entry point here can trust msg.From was authorised.
// ────────────────────────────────────────────────────────────────────────────

async Task OpenPrinterSessionAsync(long chatId, CancellationToken ct)
{
    BotPrintSession? existing;
    lock (printSessionsLock) { printSessions.TryGetValue(chatId, out existing); }
    if (existing is not null)
    {
        // Already-open session for this chat — point the user at the
        // existing status message via Telegram's reply-chip rather
        // than spawning a second session message that'd just clutter.
        try
        {
            await bot.SendMessage(chatId,
                "🖨 You already have an open printer session — tap the reply above to jump to it.",
                replyParameters: new() { MessageId = existing.StatusMessageId },
                cancellationToken: ct);
        }
        catch (Exception ex)
        {
            log.LogDebug("printer self-jump reply failed: {Err}", ex.Message);
            await bot.SendMessage(chatId, "🖨 Printer session is already open.",
                cancellationToken: ct);
        }
        return;
    }

    var st = await daemon.GetStatusAsync(ct);
    var online    = st?.Printer.Online ?? true;
    var mediaSize = st?.Printer.MediaSize ?? "A4";
    var margins   = st?.Printer.Margins ?? new PrintableMargins();
    var placeholder = await bot.SendMessage(chatId, "🖨 Opening printer session…",
        cancellationToken: ct);

    var session = new BotPrintSession
    {
        ChatId = chatId,
        StatusMessageId = placeholder.Id,
        PrinterOnline = online,
        MediaSize = mediaSize,
        Margins = margins,
    };
    lock (printSessionsLock) { printSessions[chatId] = session; }
    await RenderPrintSessionAsync(chatId, ct);
}

async Task ClosePrinterSessionAsync(long chatId, CancellationToken ct)
{
    BotPrintSession? s;
    lock (printSessionsLock)
    {
        printSessions.TryGetValue(chatId, out s);
        if (s is not null) printSessions.Remove(chatId);
    }
    if (s is null) return;
    try
    {
        await bot.EditMessageText(chatId, s.StatusMessageId,
            PrintMessage.RenderTerminated(s),
            parseMode: ParseMode.Html, replyMarkup: null,
            cancellationToken: ct);
    }
    catch (Exception ex) { log.LogDebug("close-render failed: {Err}", ex.Message); }
}

async Task RenderPrintSessionAsync(long chatId, CancellationToken ct)
{
    BotPrintSession? s;
    lock (printSessionsLock) { printSessions.TryGetValue(chatId, out s); }
    if (s is null) return;
    var (html, kb) = PrintMessage.Render(s, botUsername);
    try
    {
        await bot.EditMessageText(chatId, s.StatusMessageId, html,
            parseMode: ParseMode.Html, replyMarkup: kb,
            linkPreviewOptions: new() { IsDisabled = true },
            cancellationToken: ct);
    }
    catch (Exception ex)
    {
        if (!ex.Message.Contains("not modified", StringComparison.OrdinalIgnoreCase))
            log.LogDebug("printer render failed: {Err}", ex.Message);
    }
}

async Task StageDocumentForPrintAsync(long chatId, Document doc, CancellationToken ct)
{
    var classified = ClassifyForPrint(doc.MimeType, doc.FileName);

    if (classified.Kind == IncomingFileKind.Unsupported)
    {
        var nameForMsg = (doc.FileName ?? doc.MimeType ?? "this file")
            .Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
        await bot.SendMessage(chatId,
            $"❌ <code>{nameForMsg}</code> isn't a supported print format. " +
            "Send a PDF, PostScript, or image instead.",
            parseMode: ParseMode.Html, cancellationToken: ct);
        return;
    }

    using var ms = new MemoryStream();
    await bot.GetInfoAndDownloadFile(doc.FileId, ms, ct);
    var bytes = ms.ToArray();
    var fileName = doc.FileName ?? "document";

    if (classified.Kind == IncomingFileKind.Renderable)
    {
        if (!renderer.Enabled)
        {
            await bot.SendMessage(chatId,
                "❌ The doc-rendering service isn't enabled on this server. " +
                "Convert to PDF on your device first and resend.",
                cancellationToken: ct);
            return;
        }
        // Tell the user we're working on it — soffice cold-start can
        // take 5–10 s and the user shouldn't think the bot ignored
        // the upload.
        var notice = await bot.SendMessage(chatId,
            $"🔄 Rendering <code>{System.Net.WebUtility.HtmlEncode(fileName)}</code> to PDF…",
            parseMode: ParseMode.Html, cancellationToken: ct);
        byte[] pdfBytes;
        try
        {
            pdfBytes = await renderer.RenderAsync(bytes, fileName,
                classified.ContentType, ct);
        }
        catch (Exception ex)
        {
            log.LogWarning(ex, "render failed for {File}", fileName);
            try
            {
                // Friendly summary on its own line, raw tool output
                // in a monospace expander-style <pre><code> block —
                // keeps the failure debuggable without burying the
                // useful summary in a wall of stderr.
                string body;
                if (ex is RenderFailedRemotely rf)
                {
                    var friendlyEsc = System.Net.WebUtility.HtmlEncode(rf.Friendly);
                    var raw = rf.RawDetail.Trim();
                    if (raw.Length > 1000) raw = raw[..1000] + "…";
                    var rawEsc = System.Net.WebUtility.HtmlEncode(raw);
                    body =
                        $"❌ Rendering failed: <b>{friendlyEsc}</b>\n" +
                        (raw.Length > 0 ? $"<pre><code>{rawEsc}</code></pre>\n" : "") +
                        "💡 Tip: printing from the source app to a PDF on " +
                        "your device first usually gives more reliable output.";
                }
                else
                {
                    body =
                        $"❌ Rendering failed: <b>{System.Net.WebUtility.HtmlEncode(ex.Message)}</b>\n" +
                        "💡 Tip: printing from the source app to a PDF on " +
                        "your device first usually gives more reliable output.";
                }
                await bot.EditMessageText(chatId, notice.Id, body,
                    parseMode: ParseMode.Html, cancellationToken: ct);
            }
            catch { /* notice may be gone */ }
            return;
        }
        try { await bot.DeleteMessage(chatId, notice.Id, ct); }
        catch (Exception ex) { log.LogDebug("notice delete: {Err}", ex.Message); }

        // Substitute the rendered PDF in. Keep the user's filename
        // (with .pdf swapped in) so they recognise it in the
        // confirmation block.
        var pdfName = Path.ChangeExtension(fileName, ".pdf");
        await StageBytesForPrintAsync(chatId, pdfName, "application/pdf",
            PendingPrintKind.Pageable, pdfBytes, ct);
        return;
    }

    var pendingKind = classified.Kind == IncomingFileKind.Image
        ? PendingPrintKind.Image
        : PendingPrintKind.Pageable;
    await StageBytesForPrintAsync(chatId, fileName, classified.ContentType,
        pendingKind, bytes, ct);
}

async Task StagePhotoForPrintAsync(long chatId, PhotoSize photo, CancellationToken ct)
{
    using var ms = new MemoryStream();
    await bot.GetInfoAndDownloadFile(photo.FileId, ms, ct);
    var bytes = ms.ToArray();
    // Telegram delivers Photo as JPEG and strips dpi metadata, so
    // always images-flow with no useful 1:1 hint.
    await StageBytesForPrintAsync(chatId, "photo.jpg", "image/jpeg",
        PendingPrintKind.Image, bytes, ct);
}

async Task StageBytesForPrintAsync(
    long chatId, string fileName, string contentType,
    PendingPrintKind kind, byte[] bytes, CancellationToken ct)
{
    BotPrintSession? s;
    lock (printSessionsLock) { printSessions.TryGetValue(chatId, out s); }
    if (s is null)
    {
        // No open session — auto-open one. Same effect as the user
        // tapping 🖨 Printer first, then sending the file.
        await OpenPrinterSessionAsync(chatId, ct);
        lock (printSessionsLock) { printSessions.TryGetValue(chatId, out s); }
        if (s is null) return;
    }

    int? w = null, h = null, dpi = null;
    if (kind == PendingPrintKind.Image)
    {
        try
        {
            using var imgStream = new MemoryStream(bytes, writable: false);
            var info = await SixLabors.ImageSharp.Image.IdentifyAsync(imgStream, ct);
            w = info.Width;
            h = info.Height;
            // ImageSharp surfaces resolution in the Metadata. Most
            // formats record it in pixels-per-inch via PixelResolutionUnit
            // — when the unit is anything else (cm) we'd need to
            // convert; for the printable-direct path here all the
            // formats we accept use PixelsPerInch.
            var hRes = info.Metadata.HorizontalResolution;
            var vRes = info.Metadata.VerticalResolution;
            if (hRes > 0 && vRes > 0)
            {
                dpi = (int)Math.Round(Math.Min(hRes, vRes));
                if (dpi < PendingPrint.MinReasonableDpi) dpi = null;
            }
        }
        catch (Exception ex)
        {
            log.LogDebug("image metadata extract failed for {File}: {Err}", fileName, ex.Message);
        }
    }

    var paper = PaperSizes.Inches(s.MediaSize);
    // Convert margins (mm) to inches and subtract from paper to get
    // the safe printable rectangle. Long-axis margin is top + bottom
    // since the long axis of the paper is the vertical one in
    // portrait; the picker uses Math.Min/Max so flipping orientation
    // doesn't change the verdict.
    const double InchesPerMm = 1.0 / 25.4;
    var marginShortIn = (s.Margins.LeftMm + s.Margins.RightMm)  * InchesPerMm;
    var marginLongIn  = (s.Margins.TopMm  + s.Margins.BottomMm) * InchesPerMm;
    var pending = new PendingPrint
    {
        Id = Guid.NewGuid().ToString("N")[..8],
        Data = bytes,
        FileName = fileName,
        ContentType = contentType,
        Kind = kind,
        PixelWidth = w,
        PixelHeight = h,
        Dpi = dpi,
        PaperShortInches = paper.Short,
        PaperLongInches  = paper.Long,
        PrintableShortInches = Math.Max(0.1, paper.Short - marginShortIn),
        PrintableLongInches  = Math.Max(0.1, paper.Long  - marginLongIn),
    };
    if (pending.Fits1to1 == OneToOneFit.Printable)
        pending.Scale = PrintScaleMode.OneToOne;

    lock (printSessionsLock)
    {
        if (printSessions.TryGetValue(chatId, out var bs))
        {
            bs.Pending = pending;
            bs.View = PrintPickerView.Main;
        }
    }
    await RenderPrintSessionAsync(chatId, ct);

    // For Pageable inputs (direct PDFs or rendered docs), ask the
    // renderer how many pages there are. This drives the per-page
    // checkbox UI for short PDFs (≤10 pages) and the page-count
    // info shown next to the filename. Best-effort — null on any
    // failure, no UI impact beyond the lack of a count.
    if (kind == PendingPrintKind.Pageable && renderer.Enabled)
    {
        var n = await renderer.GetPdfPageCountAsync(bytes, fileName, ct);
        if (n is int count)
        {
            lock (printSessionsLock)
            {
                if (printSessions.TryGetValue(chatId, out var bs2) &&
                    bs2.Pending is { } cur && cur.Id == pending.Id)
                {
                    cur.PageCount = count;
                }
            }
            await RenderPrintSessionAsync(chatId, ct);
        }
    }
}

/// <summary>
/// Classify an incoming document by MIME type / extension. Pageable
/// goes straight to the print queue, Image opens the scale/orient
/// flow, Renderable bounces through the renderer daemon
/// (libreoffice → PDF) before becoming Pageable.
/// </summary>
static (IncomingFileKind Kind, string ContentType) ClassifyForPrint(string? mime, string? fileName)
{
    var mimeLower = (mime ?? "").ToLowerInvariant();
    var ext = Path.GetExtension(fileName ?? "").ToLowerInvariant();

    if (mimeLower == "application/pdf" || ext == ".pdf")
        return (IncomingFileKind.Pageable, "application/pdf");
    if (mimeLower == "application/postscript" || mimeLower == "application/x-postscript"
        || ext is ".ps" or ".eps")
        return (IncomingFileKind.Pageable, "application/postscript");

    if (mimeLower.StartsWith("image/") || ext is ".jpg" or ".jpeg" or ".png"
        or ".webp" or ".gif" or ".bmp" or ".tif" or ".tiff")
    {
        var ct = mimeLower.StartsWith("image/") ? mimeLower : ext switch
        {
            ".jpg" or ".jpeg" => "image/jpeg",
            ".png"  => "image/png",
            ".webp" => "image/webp",
            ".gif"  => "image/gif",
            ".bmp"  => "image/bmp",
            ".tif" or ".tiff" => "image/tiff",
            _ => "application/octet-stream",
        };
        return (IncomingFileKind.Image, ct);
    }

    // Office formats — bounce through the renderer daemon. We list
    // the common MIMEs explicitly because Telegram clients tend to
    // tag user uploads with a generic "application/octet-stream"
    // and we'd rather match on filename extension as a fallback than
    // miss a docx upload entirely.
    if (mimeLower
        is "application/msword"
        or "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        or "application/vnd.oasis.opendocument.text"
        or "application/rtf"
        or "text/rtf"
        or "text/plain"
        or "application/vnd.ms-excel"
        or "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        or "application/vnd.oasis.opendocument.spreadsheet"
        or "application/vnd.ms-powerpoint"
        or "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        or "application/vnd.oasis.opendocument.presentation"
        || ext is ".doc" or ".docx" or ".odt" or ".rtf" or ".txt"
              or ".xls" or ".xlsx" or ".ods"
              or ".ppt" or ".pptx" or ".odp")
    {
        var ct = mimeLower.StartsWith("application/") || mimeLower.StartsWith("text/")
            ? mimeLower
            : ext switch
            {
                ".doc"  => "application/msword",
                ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                ".odt"  => "application/vnd.oasis.opendocument.text",
                ".rtf"  => "application/rtf",
                ".txt"  => "text/plain",
                ".xls"  => "application/vnd.ms-excel",
                ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                ".ods"  => "application/vnd.oasis.opendocument.spreadsheet",
                ".ppt"  => "application/vnd.ms-powerpoint",
                ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                ".odp"  => "application/vnd.oasis.opendocument.presentation",
                _ => "application/octet-stream",
            };
        return (IncomingFileKind.Renderable, ct);
    }

    return (IncomingFileKind.Unsupported, "application/octet-stream");
}

async Task HandlePrintCallbackAsync(long chatId, string data, CancellationToken ct)
{
    // Verbs:
    //   print:pick:<scale|orient|main>:<pendingId>   — switch picker view
    //   print:set:<scale|orient>:<pendingId>:<value> — apply value, back to main
    //   print:confirm:<pendingId>                    — kick off the print
    //   print:cancel:<pendingId>                     — drop the pending
    var parts = data.Split(':');
    if (parts.Length < 3) return;
    var verb = parts[1];

    BotPrintSession? s;
    lock (printSessionsLock) { printSessions.TryGetValue(chatId, out s); }
    if (s is null) return;

    // For verbs that carry a pendingId, ignore the tap if the pending
    // has changed under us (stale callback from a prior file upload).
    bool MatchesCurrent(string id) => s.Pending is { } cur && cur.Id == id;

    switch (verb)
    {
        case "pick":
        {
            if (parts.Length < 4) return;
            var what = parts[2];
            var pid = parts[3];
            if (pid != "_" && !MatchesCurrent(pid)) return;
            lock (printSessionsLock)
            {
                if (printSessions.TryGetValue(chatId, out var bs))
                    bs.View = what switch
                    {
                        "scale"   => PrintPickerView.Scale,
                        "orient"  => PrintPickerView.Orientation,
                        "pages"   => PrintPickerView.Pages,
                        "rangekb" => PrintPickerView.PageRangeKeyboard,
                        _ => PrintPickerView.Main,
                    };
            }
            await RenderPrintSessionAsync(chatId, ct);
            break;
        }
        case "set":
        {
            if (parts.Length < 5) return;
            var what  = parts[2];
            var pid   = parts[3];
            var value = parts[4];
            if (!MatchesCurrent(pid)) return;
            lock (printSessionsLock)
            {
                if (!printSessions.TryGetValue(chatId, out var bs) || bs.Pending is null) break;
                if (what == "scale")
                {
                    bs.Pending.Scale = value switch
                    {
                        "onetoone" => PrintScaleMode.OneToOne,
                        "fit"      => PrintScaleMode.Fit,
                        "fill"     => PrintScaleMode.Fill,
                        _ => bs.Pending.Scale,
                    };
                }
                else if (what == "orient")
                {
                    bs.Pending.Orientation = value switch
                    {
                        "auto"      => PrintOrientation.Auto,
                        "portrait"  => PrintOrientation.Portrait,
                        "landscape" => PrintOrientation.Landscape,
                        _ => bs.Pending.Orientation,
                    };
                }
                else if (what == "pages")
                {
                    bs.Pending.PageSelection = value switch
                    {
                        "all"  => PageSelection.All,
                        "odd"  => PageSelection.Odd,
                        "even" => PageSelection.Even,
                        _ => bs.Pending.PageSelection,
                    };
                    // Picking a preset clears any prior custom range —
                    // PageRange-non-empty wins over the preset, so
                    // leaving stale custom data would silently override
                    // the user's just-now choice.
                    bs.Pending.PageRange = "";
                }
                bs.View = what == "pages" ? PrintPickerView.Pages : PrintPickerView.Main;
            }
            await RenderPrintSessionAsync(chatId, ct);
            break;
        }
        case "cancel":
        {
            var pid = parts[2];
            if (!MatchesCurrent(pid)) return;
            lock (printSessionsLock)
            {
                if (printSessions.TryGetValue(chatId, out var bs))
                {
                    bs.Pending = null;
                    bs.View = PrintPickerView.Main;
                }
            }
            await RenderPrintSessionAsync(chatId, ct);
            break;
        }
        case "confirm":
        {
            var pid = parts[2];
            if (!MatchesCurrent(pid)) return;
            await ExecutePrintAsync(chatId, pid, ct);
            break;
        }
        case "togglepage":
        {
            // print:togglepage:<pid>:<pageNumber> — flip page N's
            // membership in PageRange. Used by the per-page
            // checkbox row in the Pages picker.
            if (parts.Length < 4) return;
            var pid = parts[2];
            if (!MatchesCurrent(pid)) return;
            if (!int.TryParse(parts[3], out var pageNum)) return;
            lock (printSessionsLock)
            {
                if (!printSessions.TryGetValue(chatId, out var bs2) ||
                    bs2.Pending is null) break;
                if (bs2.Pending.PageCount is not int pc || pc <= 0) break;
                var current = PageRangeNotation.Parse(bs2.Pending.PageRange, pc);
                // First click against an empty PageRange while a
                // preset is active: seed the set from the preset so
                // the toggle reads as "remove from current
                // selection" rather than "include only this page".
                if (current.Count == 0 && string.IsNullOrEmpty(bs2.Pending.PageRange))
                {
                    for (int i = 1; i <= pc; i++)
                    {
                        var include = bs2.Pending.PageSelection switch
                        {
                            PageSelection.Odd  => i % 2 == 1,
                            PageSelection.Even => i % 2 == 0,
                            _ => true,
                        };
                        if (include) current.Add(i);
                    }
                }
                if (!current.Add(pageNum)) current.Remove(pageNum);
                bs2.Pending.PageRange = PageRangeNotation.Serialize(current);
                bs2.View = PrintPickerView.Pages;
            }
            await RenderPrintSessionAsync(chatId, ct);
            break;
        }
        case "rangekey":
        {
            // print:rangekey:<pid>:<value> — append/erase/clear/commit
            // a character to the page-range buffer. Acts like a tiny
            // numeric keyboard.
            if (parts.Length < 4) return;
            var pid = parts[2];
            if (!MatchesCurrent(pid)) return;
            var value = parts[3];
            lock (printSessionsLock)
            {
                if (!printSessions.TryGetValue(chatId, out var bs2) ||
                    bs2.Pending is null) break;
                var buf = bs2.Pending.PageRange ?? "";
                switch (value)
                {
                    case "BS":
                        if (buf.Length > 0) buf = buf[..^1];
                        break;
                    case "CLR":
                        buf = "";
                        break;
                    case "OK":
                        bs2.View = PrintPickerView.Main;
                        break;
                    default:
                        // Digit / "-" / "," — just append. The string
                        // is validated implicitly by the daemon's
                        // page-range parser; if the user types
                        // "1-2-3,," CUPS will reject the job, which
                        // is fine.
                        if (value.Length == 1) buf += value;
                        break;
                }
                bs2.Pending.PageRange = buf;
            }
            await RenderPrintSessionAsync(chatId, ct);
            break;
        }
    }
}

async Task ExecutePrintAsync(long chatId, string pendingId, CancellationToken ct)
{
    PendingPrint? p;
    lock (printSessionsLock)
    {
        if (!printSessions.TryGetValue(chatId, out var bs)) return;
        if (bs.Pending is null || bs.Pending.Id != pendingId) return;
        if (bs.Printing) return;          // re-entry guard
        bs.Printing = true;
        p = bs.Pending;
    }
    await RenderPrintSessionAsync(chatId, ct);

    bool ok = false;
    string? error = null;
    try
    {
        using var content = new MultipartFormDataContent();
        var fileContent = new ByteArrayContent(p!.Data);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue(p.ContentType);
        content.Add(fileContent, "file", p.FileName);
        content.Add(new StringContent(p.Scale.ToString()), "scale");
        content.Add(new StringContent(p.Orientation.ToString()), "orientation");
        // Custom range wins over the preset when non-empty — see
        // the comment on PendingPrint.PageRange. Daemon's /print
        // form parser reads pageRange first and falls back to
        // pageSelection only if pageRange is missing.
        if (!string.IsNullOrEmpty(p.PageRange))
            content.Add(new StringContent(p.PageRange), "pageRange");
        else
            content.Add(new StringContent(p.PageSelection.ToString()), "pageSelection");

        // Daemon talks unix socket; one-shot HttpClient with the same
        // ConnectCallback shape DaemonClient uses internally.
        using var http = new HttpClient(new SocketsHttpHandler
        {
            ConnectCallback = async (_, innerCt) =>
            {
                var sock = new System.Net.Sockets.Socket(
                    System.Net.Sockets.AddressFamily.Unix,
                    System.Net.Sockets.SocketType.Stream,
                    System.Net.Sockets.ProtocolType.Unspecified);
                await sock.ConnectAsync(
                    new System.Net.Sockets.UnixDomainSocketEndPoint(socketPath), innerCt);
                return new System.Net.Sockets.NetworkStream(sock, ownsSocket: true);
            }
        }) { BaseAddress = new Uri("http://localhost") };
        var resp = await http.PostAsync("/print", content, ct);
        ok = resp.IsSuccessStatusCode;
        if (!ok) error = $"HTTP {(int)resp.StatusCode}";
    }
    catch (Exception ex)
    {
        error = ex.Message;
        log.LogError(ex, "print of {File} failed", p?.FileName);
    }

    lock (printSessionsLock)
    {
        if (printSessions.TryGetValue(chatId, out var bs))
        {
            bs.Printing = false;
            bs.History.Insert(0, new PrintHistoryEntry(
                DateTimeOffset.Now, p?.FileName ?? "?", ok, error));
            if (bs.History.Count > BotPrintSession.HistoryCap)
                bs.History.RemoveRange(BotPrintSession.HistoryCap,
                    bs.History.Count - BotPrintSession.HistoryCap);
            // Drop the pending whether print succeeded or failed —
            // user re-sends to retry; matches the scan flow's "no
            // automatic retry" stance.
            bs.Pending = null;
        }
    }
    await RenderPrintSessionAsync(chatId, ct);
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
                    // own this in memory, rebuild it. Format selection
                    // travels in the daemon's opaque metadata bag, so we
                    // recover it from there.
                    sessions[s.Id] = new BotSession
                    {
                        DaemonSessionId = s.Id,
                        ChatId = s.OwnerChatId,
                        StatusMessageId = s.OwnerStatusMessageId,
                        Params = s.Params,
                        Format = ParseFormatFromMetadata(s.Metadata),
                        ExpiresAt = s.ExpiresAt,
                        ScanCount = s.ScanCount,
                    };
                }
                else if (sessions.TryGetValue(s.Id, out var bs))
                {
                    // SessionOpened is also re-emitted on PATCH-params
                    // and metadata updates — pick up changes here.
                    // Format is intentionally NOT re-read from metadata:
                    // the bot is the only writer to that key, so every
                    // SessionOpened we receive after reconstruction is
                    // an echo of a value we just wrote. Re-applying it
                    // would race with rapid user toggles — a stale echo
                    // arriving between two fast taps would overwrite
                    // the newer local value before its own echo lands.
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
            // Daemon fires exactly one event per scan now — it carries
            // the raw TIFF blob, the bot decodes once and produces all
            // variants on its side. Run delivery on a worker so the SSE
            // event loop doesn't block on decode/encode (a 600 dpi scan
            // can take several seconds of CPU).
            BotSession? bs;
            lock (sessionsLock) { sessions.TryGetValue(ev.SessionId, out bs); }
            var sessionId = ev.SessionId;
            if (bs is not null)
            {
                Interlocked.Increment(ref inFlightCount);
                _ = Task.Run(async () =>
                {
                    try { await DeliverScanAsync(sessionId, seq, bs, ct); }
                    catch (Exception ex)
                    {
                        log.LogError(ex, "deliver scan {Session}#{Seq} failed", sessionId, seq);
                    }
                    finally { Interlocked.Decrement(ref inFlightCount); }
                });
            }
            lock (sessionsLock)
            {
                if (sessions.TryGetValue(ev.SessionId, out var bs2))
                {
                    bs2.ScanCount = seq;
                    bs2.LastUploadedSeq = seq;
                    // If there's a queued scan about to start, keep
                    // Scanning=true so the button doesn't flicker to
                    // idle between SessionImageReady and the upcoming
                    // SessionScanning(next-seq).
                    if (bs2.QueuedScans == 0) bs2.Scanning = false;
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
            }
            break;
        }
    }
}

async Task RerenderAsync(string sessionId, CancellationToken ct,
    PickerView? viewOverride = null)
{
    BotSession? s;
    lock (sessionsLock)
    {
        if (sessions.TryGetValue(sessionId, out s) && viewOverride is { } v)
            s.View = v;
    }
    if (s is null) return;
    var (html, kb) = StatusMessage.Render(s, botUsername, s.View);
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
// Scan delivery: fetch raw TIFF, decode + encode + thumbnail, upload to TG.
// All bytes are in-memory and released as soon as Telegram accepts the
// album — no on-disk staging, no daemon-side accumulation.
// ────────────────────────────────────────────────────────────────────────────

async Task DeliverScanAsync(string sessionId, int seq, BotSession bs, CancellationToken ct)
{
    // 1. Fetch the raw TIFF from the daemon. The daemon keeps its
    //    copy until we DELETE (step 4) — the 10-min session-idle
    //    window is the TTL backstop if we never get there. That
    //    means transient TG upload failures here can simply re-run
    //    DeliverScanAsync without re-scanning.
    using var tiffMs = new MemoryStream();
    using (var tiffStream = await daemon.FetchScanAsync(sessionId, seq, ct))
    {
        await tiffStream.CopyToAsync(tiffMs, ct);
    }
    tiffMs.Position = 0;

    // 2. Decode once, encode each requested format, build per-variant
    //    overlay thumbnails. ImagePipeline owns the disposal contract:
    //    each EncodedVariant holds two streams; the using-scope below
    //    disposes them all when we leave.
    var variants = await pipeline.ProcessAsync(
        tiffMs, bs.Params.Dpi, seq, bs.Format, ct);
    try
    {
        var caption = $"📷 {bs.Params.Dpi} dpi · scan #{seq}";

        if (variants.Count == 1)
        {
            // Single format → SendDocument. Thumbnail name doesn't need
            // to be unique here because there's only one attach.
            var v = variants[0];
            await bot.SendDocument(bs.ChatId,
                new InputFileStream(v.Data, v.FileName),
                caption: caption,
                thumbnail: new InputFileStream(v.Thumbnail, "thumb.jpg"),
                cancellationToken: ct);
        }
        else
        {
            // Multi-format → media group (album). Crucial correctness
            // note: Telegram.Bot derives the multipart `attach://`
            // reference from each InputFileStream's FileName, so two
            // streams named "thumb.jpg" collide and the API surfaces
            // "Wrong file identifier" on every item past the first.
            // Variant-suffixed thumbnail names avoid that.
            var medias = new List<IAlbumInputMedia>(variants.Count);
            for (int i = 0; i < variants.Count; i++)
            {
                var v = variants[i];
                medias.Add(new InputMediaDocument(
                    new InputFileStream(v.Data, v.FileName))
                {
                    Thumbnail = new InputFileStream(
                        v.Thumbnail, $"thumb-{i}.jpg"),
                    // Only the first item's caption is shown above the
                    // album — the rest are hidden, so put the summary
                    // on slot 0.
                    Caption = i == 0 ? caption : null,
                });
            }
            await bot.SendMediaGroup(bs.ChatId, medias, cancellationToken: ct);
        }
        log.LogInformation("delivered {Session}#{Seq} ({N} formats)",
            sessionId, seq, variants.Count);

        // 4. Tell the daemon to drop its TIFF copy. Done last so that
        //    a Telegram-upload failure leaves the daemon's blob intact
        //    for a retry. Idempotent — best-effort, doesn't fail the
        //    delivery if the daemon round-trip glitches.
        try
        {
            await daemon.DeleteScanAsync(sessionId, seq, ct);
        }
        catch (Exception ex)
        {
            log.LogDebug(
                "DELETE scan {Session}#{Seq} failed (will be reaped at session-end): {Err}",
                sessionId, seq, ex.Message);
        }
    }
    finally
    {
        foreach (var v in variants) v.Dispose();
    }
}

// Light-weight printer-status sync. The scanner has a full SSE feed
// (online/offline transitions) on the daemon side; printers don't —
// for now the bot just polls /status periodically and refreshes any
// open print sessions whose cached online flag has drifted. Cheap,
// no daemon-side changes needed, can be replaced with proper SSE
// once a real printer is wired up and lpstat polling lives on the
// daemon side.
async Task PollPrinterStatusAsync(CancellationToken ct)
{
    var period = TimeSpan.FromSeconds(30);
    while (!ct.IsCancellationRequested)
    {
        try { await Task.Delay(period, ct); } catch { return; }
        DeviceStatus? st;
        try { st = await daemon.GetStatusAsync(ct); }
        catch { continue; }
        if (st is null) continue;

        List<long> changedChats = [];
        lock (printSessionsLock)
        {
            foreach (var (chatId, ps) in printSessions)
            {
                bool changed = false;
                if (ps.PrinterOnline != st.Printer.Online)
                {
                    ps.PrinterOnline = st.Printer.Online;
                    changed = true;
                }
                var ms = st.Printer.MediaSize ?? "A4";
                if (!string.Equals(ps.MediaSize, ms, StringComparison.OrdinalIgnoreCase))
                {
                    ps.MediaSize = ms;
                    changed = true;
                }
                if (changed) changedChats.Add(chatId);
            }
        }
        foreach (var chatId in changedChats)
        {
            try { await RenderPrintSessionAsync(chatId, ct); } catch { }
        }
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
