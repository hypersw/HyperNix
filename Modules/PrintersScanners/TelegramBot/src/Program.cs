using System.Net.Http.Headers;
using System.Net.Sockets;
using Telegram.Bot;
using Telegram.Bot.Types;
using Telegram.Bot.Types.Enums;
using Telegram.Bot.Types.ReplyMarkups;

// Configuration from environment.
// Token file: prefer PRINTSCAN_BOT_TOKEN_FILE, fallback to systemd credentials directory.
var tokenFile = Environment.GetEnvironmentVariable("PRINTSCAN_BOT_TOKEN_FILE");
if (string.IsNullOrEmpty(tokenFile))
{
    var credDir = Environment.GetEnvironmentVariable("CREDENTIALS_DIRECTORY");
    tokenFile = credDir is not null ? Path.Combine(credDir, "telegram-token") : null;
}
if (string.IsNullOrEmpty(tokenFile) || !File.Exists(tokenFile))
    throw new Exception($"Bot token file not found (PRINTSCAN_BOT_TOKEN_FILE or CREDENTIALS_DIRECTORY/telegram-token). Tried: {tokenFile}");
var socketPath = Environment.GetEnvironmentVariable("PRINTSCAN_SOCKET")
    ?? "/run/printscan/api.sock";

// Parse allowed users from JSON: [{"id":123,"name":"alice"}, ...]
var allowedUsersJson = Environment.GetEnvironmentVariable("PRINTSCAN_ALLOWED_USERS") ?? "[]";
var allowedUsersList = System.Text.Json.JsonSerializer.Deserialize<List<AllowedUser>>(allowedUsersJson,
    new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
var allowedUsers = allowedUsersList.ToDictionary(u => u.Id, u => u.Name);

var token = (await System.IO.File.ReadAllTextAsync(tokenFile)).Trim();
var bot = new TelegramBotClient(token);

// HTTP client that talks to daemon via Unix socket
var daemonClient = new HttpClient(new SocketsHttpHandler
{
    ConnectCallback = async (context, ct) =>
    {
        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        await socket.ConnectAsync(new UnixDomainSocketEndPoint(socketPath), ct);
        return new NetworkStream(socket, ownsSocket: true);
    }
})
{
    BaseAddress = new Uri("http://localhost") // hostname is ignored for Unix sockets
};

Console.WriteLine($"PrintScan Telegram bot starting (allowed users: {string.Join(", ", allowedUsers.Select(u => $"{u.Value}({u.Key})"))})");

// Register bot commands (visible in Telegram's menu)
await bot.SetMyCommands([
    new BotCommand { Command = "scan", Description = "📷 Scan a document" },
    new BotCommand { Command = "status", Description = "📊 Printer & scanner status" },
    new BotCommand { Command = "help", Description = "❓ How to use this bot" },
]);
Console.WriteLine("Bot commands registered");

// Persistent reply keyboard — always visible, phone-friendly
var mainKeyboard = new ReplyKeyboardMarkup(
    new[]
    {
        new KeyboardButton[] { "📷 Scan", "📊 Status" },
    })
{
    ResizeKeyboard = true, // compact size
    IsPersistent = true,   // always visible
};

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

// Long-polling loop
var offset = 0;
while (!cts.IsCancellationRequested)
{
    try
    {
        var updates = await bot.GetUpdates(offset, timeout: 30, cancellationToken: cts.Token);
        foreach (var update in updates)
        {
            offset = update.Id + 1;
            _ = Task.Run(() => HandleUpdate(update, cts.Token));
        }
    }
    catch (OperationCanceledException) { break; }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"Polling error: {ex.Message}");
        await Task.Delay(5000, cts.Token);
    }
}

async Task HandleUpdate(Update update, CancellationToken ct)
{
    try
    {
        if (update.Message is { } message)
            await HandleMessage(message, ct);
        else if (update.CallbackQuery is { } callback)
            await HandleCallback(callback, ct);
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"Error handling update {update.Id}: {ex.Message}");
    }
}

async Task HandleMessage(Message message, CancellationToken ct)
{
    var userId = message.From?.Id ?? 0;
    var chatId = message.Chat.Id;

    // Access control
    if (allowedUsers.Count > 0 && !allowedUsers.ContainsKey(userId))
    {
        Console.Error.WriteLine($"Unauthorized access attempt from user {userId} ({message.From?.Username ?? "unknown"})");
        await bot.SendMessage(chatId, "⛔ Not authorized", cancellationToken: ct);
        return;
    }
    if (allowedUsers.Count > 0)
        Console.WriteLine($"Request from {allowedUsers[userId]} ({userId}): {message.Text ?? message.Document?.FileName ?? "media"}");

    // File received → print
    if (message.Document is { } doc)
    {
        await HandlePrintDocument(chatId, doc, ct);
        return;
    }

    // Photo received → print
    if (message.Photo is { Length: > 0 } photos)
    {
        await HandlePrintPhoto(chatId, photos.Last(), ct);
        return;
    }

    // Commands — match both /commands and keyboard button text
    var text = message.Text?.Trim() ?? "";
    var cmd = text.Split(' ', '@')[0].ToLower();
    switch (cmd)
    {
        case "/scan":
        case "📷 scan":
            await ShowScanOptions(chatId, ct);
            break;
        case "/status":
        case "📊 status":
            await ShowStatus(chatId, ct);
            break;
        case "/help":
        case "/start":
            await bot.SendMessage(chatId, """
                🖨️ <b>PrintScan Bot</b>

                Send a <b>PDF</b> or <b>image</b> to print it.
                Use the buttons below or type commands.
                """, parseMode: ParseMode.Html, replyMarkup: mainKeyboard, cancellationToken: ct);
            break;
        default:
            await bot.SendMessage(chatId, "Send a file to print, or tap 📷 Scan below.",
                replyMarkup: mainKeyboard, cancellationToken: ct);
            break;
    }
}

async Task HandlePrintDocument(long chatId, Document doc, CancellationToken ct)
{
    var status = await bot.SendMessage(chatId, $"🖨️ Printing <code>{doc.FileName}</code>...",
        parseMode: ParseMode.Html, cancellationToken: ct);

    try
    {
        using var ms = new MemoryStream();
        await bot.GetInfoAndDownloadFile(doc.FileId, ms, ct);
        ms.Position = 0;

        using var content = new MultipartFormDataContent();
        var fileContent = new StreamContent(ms);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        content.Add(fileContent, "file", doc.FileName ?? "document");

        var response = await daemonClient.PostAsync("/print", content, ct);
        if (response.IsSuccessStatusCode)
            await bot.EditMessageText(chatId, status.Id, $"✅ Printed <code>{doc.FileName}</code>",
                parseMode: ParseMode.Html, cancellationToken: ct);
        else
            await bot.EditMessageText(chatId, status.Id, $"❌ Print failed: {response.StatusCode}",
                cancellationToken: ct);
    }
    catch (Exception ex)
    {
        await bot.EditMessageText(chatId, status.Id, $"❌ Print error: {ex.Message}",
            cancellationToken: ct);
    }
}

async Task HandlePrintPhoto(long chatId, PhotoSize photo, CancellationToken ct)
{
    var status = await bot.SendMessage(chatId, "🖨️ Printing photo...", cancellationToken: ct);

    try
    {
        using var ms = new MemoryStream();
        await bot.GetInfoAndDownloadFile(photo.FileId, ms, ct);
        ms.Position = 0;

        using var content = new MultipartFormDataContent();
        var fileContent = new StreamContent(ms);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg");
        content.Add(fileContent, "file", "photo.jpg");

        var response = await daemonClient.PostAsync("/print", content, ct);
        if (response.IsSuccessStatusCode)
            await bot.EditMessageText(chatId, status.Id, "✅ Photo printed", cancellationToken: ct);
        else
            await bot.EditMessageText(chatId, status.Id, $"❌ Print failed: {response.StatusCode}",
                cancellationToken: ct);
    }
    catch (Exception ex)
    {
        await bot.EditMessageText(chatId, status.Id, $"❌ Print error: {ex.Message}",
            cancellationToken: ct);
    }
}

async Task ShowScanOptions(long chatId, CancellationToken ct)
{
    var keyboard = new InlineKeyboardMarkup()
        .AddButton("📷 200 dpi (fast)", "scan:200:jpeg:90")
        .AddNewRow()
        .AddButton("📷 300 dpi", "scan:300:jpeg:90")
        .AddNewRow()
        .AddButton("📷 600 dpi (quality)", "scan:600:jpeg:95")
        .AddNewRow()
        .AddButton("🖼️ PNG 300 dpi (lossless)", "scan:300:png:0")
        .AddNewRow()
        .AddButton("🖼️ TIFF 600 dpi (archive)", "scan:600:tiff:0");

    await bot.SendMessage(chatId, "Choose scan settings:", replyMarkup: keyboard, cancellationToken: ct);
}

async Task HandleCallback(CallbackQuery callback, CancellationToken ct)
{
    var chatId = callback.Message!.Chat.Id;
    var userId = callback.From.Id;

    if (allowedUsers.Count > 0 && !allowedUsers.ContainsKey(userId))
    {
        Console.Error.WriteLine($"Unauthorized callback from user {userId}");
        await bot.AnswerCallbackQuery(callback.Id, "Not authorized", cancellationToken: ct);
        return;
    }

    var data = callback.Data ?? "";
    if (data.StartsWith("scan:"))
    {
        var parts = data.Split(':');
        if (parts.Length >= 4)
        {
            var dpi = parts[1];
            var format = parts[2];
            var quality = parts[3];

            await bot.AnswerCallbackQuery(callback.Id, "Scanning...", cancellationToken: ct);
            await bot.EditMessageText(chatId, callback.Message.Id,
                $"📷 Scanning at {dpi} dpi ({format})...", cancellationToken: ct);

            try
            {
                // Start scan
                using var scanContent = new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["dpi"] = dpi,
                    ["format"] = format,
                    ["quality"] = quality,
                });
                var scanResp = await daemonClient.PostAsync("/scan", scanContent, ct);
                var scanJson = await scanResp.Content.ReadAsStringAsync(ct);
                var jobId = System.Text.Json.JsonDocument.Parse(scanJson)
                    .RootElement.GetProperty("id").GetString();

                // Poll for completion
                for (var i = 0; i < 120; i++) // up to 2 minutes
                {
                    await Task.Delay(1000, ct);
                    var jobResp = await daemonClient.GetAsync($"/scan/{jobId}", ct);

                    if (jobResp.Content.Headers.ContentType?.MediaType?.StartsWith("image/") == true)
                    {
                        // Scan complete — download and send to user
                        var imageStream = await jobResp.Content.ReadAsStreamAsync(ct);
                        var fileName = $"scan-{jobId}.{format}";

                        await bot.SendDocument(chatId, new InputFileStream(imageStream, fileName),
                            caption: $"✅ Scanned at {dpi} dpi", cancellationToken: ct);

                        await bot.DeleteMessage(chatId, callback.Message.Id, ct);
                        return;
                    }

                    var status = System.Text.Json.JsonDocument.Parse(
                        await jobResp.Content.ReadAsStringAsync(ct));
                    var jobStatus = status.RootElement.GetProperty("status").GetString();

                    if (jobStatus == "Failed")
                    {
                        var error = status.RootElement.GetProperty("error").GetString();
                        await bot.EditMessageText(chatId, callback.Message.Id,
                            $"❌ Scan failed: {error}", cancellationToken: ct);
                        return;
                    }
                }

                await bot.EditMessageText(chatId, callback.Message.Id,
                    "❌ Scan timed out", cancellationToken: ct);
            }
            catch (Exception ex)
            {
                await bot.EditMessageText(chatId, callback.Message.Id,
                    $"❌ Scan error: {ex.Message}", cancellationToken: ct);
            }
        }
    }
}

async Task ShowStatus(long chatId, CancellationToken ct)
{
    try
    {
        var resp = await daemonClient.GetAsync("/status", ct);
        var json = await resp.Content.ReadAsStringAsync(ct);
        var status = System.Text.Json.JsonDocument.Parse(json);
        var printer = status.RootElement.GetProperty("printer");
        var scanner = status.RootElement.GetProperty("scanner");

        var printerOnline = printer.GetProperty("online").GetBoolean();
        var scannerOnline = scanner.GetProperty("online").GetBoolean();

        await bot.SendMessage(chatId, $"""
            📊 <b>Status</b>

            🖨️ Printer: {(printerOnline ? "✅ online" : "⚠️ offline")}
            📷 Scanner: {(scannerOnline ? "✅ online" : "⚠️ offline")}
            """, parseMode: ParseMode.Html, cancellationToken: ct);
    }
    catch (Exception)
    {
        await bot.SendMessage(chatId, """
            📊 <b>Status</b>

            🖨️ Printer: 🔌 unreachable
            📷 Scanner: 🔌 unreachable
            """, parseMode: ParseMode.Html, cancellationToken: ct);
    }
}

record AllowedUser(long Id, string Name);
