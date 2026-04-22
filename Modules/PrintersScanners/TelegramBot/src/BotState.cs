using PrintScan.Shared;
using Telegram.Bot.Types.ReplyMarkups;

namespace PrintScan.TelegramBot;

/// <summary>
/// Per-session state owned by this bot process. Reconstructed from the
/// daemon's SSE replay (<c>session.opened</c> primer) on startup.
/// </summary>
public sealed class BotSession
{
    public required string DaemonSessionId { get; init; }
    public required long ChatId { get; init; }
    public required int StatusMessageId { get; init; }
    public required ScanParams Params { get; set; }   // mutable: PATCH updates
    public DateTimeOffset ExpiresAt { get; set; }
    public int ScanCount { get; set; }
    public bool ScannerOnline { get; set; }
    public bool Scanning { get; set; }
    public int LastUploadedSeq { get; set; }
}

/// <summary>
/// Inline "which picker is currently expanded" for the session status
/// message. We edit the same message between these views so the user
/// never gets a new message per interaction.
/// </summary>
public enum PickerView
{
    Main,       // [Fmt] [DPI] / [Scan] / [End]
    Format,     // JPG / PNG / TIFF / [back]
    Dpi,        // 100 / 200 / 300 / 600 / 1200 / [back]
}

public static class StatusMessage
{
    public static readonly int[] NativeDpis = [100, 200, 300, 600, 1200];
    public const int DefaultDpi = 200;
    public const ScanFormat DefaultFormat = ScanFormat.Jpeg;

    public static ScanParams Defaults() => new(
        Dpi: DefaultDpi,
        Format: DefaultFormat,
        JpegQuality: 90);

    public static (string Html, InlineKeyboardMarkup Keyboard) Render(
        BotSession s, PickerView view = PickerView.Main)
    {
        var html = RenderHtml(s);
        var keyboard = view switch
        {
            PickerView.Format => RenderFormatPicker(s),
            PickerView.Dpi    => RenderDpiPicker(s),
            _                 => RenderMain(s),
        };
        return (html, keyboard);
    }

    public static string RenderTerminated(
        BotSession s, SessionTerminationReason reason, string? newOwner)
    {
        var reasonText = reason switch
        {
            SessionTerminationReason.Timeout  => "⏰ Session expired",
            SessionTerminationReason.Takeover => $"🚪 Session taken over by {newOwner ?? "another user"}",
            SessionTerminationReason.Closed   => "🚪 Session ended",
            _ => "Session ended"
        };
        return $"{reasonText}\n📑 Final count: <b>{s.ScanCount}</b>";
    }

    // ─── HTML body ─────────────────────────────────────────────────────────

    private static string RenderHtml(BotSession s)
    {
        var remain = s.ExpiresAt - DateTimeOffset.UtcNow;
        var mins = remain.TotalSeconds < 0 ? 0 : (int)Math.Ceiling(remain.TotalMinutes);
        var fmt = s.Params.Format.ToString().ToUpperInvariant();

        var scannerLine = (s.Scanning, s.ScannerOnline) switch
        {
            (true, _)      => "📡 Scanner: 📷 <i>scanning…</i>",
            (false, true)  => "📡 Scanner: ✅ ready — tap Scan (or press scanner button)",
            (false, false) => "📡 Scanner: ⏳ <i>waiting — power on or press scanner button</i>",
        };

        return $"""
            📷 <b>Scanner session</b> · {mins} min left
            Format: <b>{fmt}</b> · Resolution: <b>{s.Params.Dpi} dpi</b>
            {scannerLine}
            📑 Scans delivered: <b>{s.ScanCount}</b>
            """;
    }

    // ─── Keyboards ─────────────────────────────────────────────────────────

    private static InlineKeyboardMarkup RenderMain(BotSession s)
    {
        var sid = s.DaemonSessionId;
        var fmt = s.Params.Format.ToString().ToUpperInvariant();
        var rows = new List<InlineKeyboardButton[]>();
        // Row 1: tap-to-change parameter buttons
        rows.Add(new[]
        {
            InlineKeyboardButton.WithCallbackData($"📄 {fmt}",              $"pick:fmt:{sid}"),
            InlineKeyboardButton.WithCallbackData($"📏 {s.Params.Dpi} dpi", $"pick:dpi:{sid}"),
        });
        if (!s.Scanning)
        {
            rows.Add(new[] { InlineKeyboardButton.WithCallbackData("📷 Scan", $"scan:{sid}") });
        }
        rows.Add(new[] { InlineKeyboardButton.WithCallbackData("🚪 End session", $"end:{sid}") });
        return new InlineKeyboardMarkup(rows);
    }

    private static InlineKeyboardMarkup RenderFormatPicker(BotSession s)
    {
        var sid = s.DaemonSessionId;
        var cur = s.Params.Format;
        string mark(ScanFormat f) => f == cur ? " ✓" : "";
        return new InlineKeyboardMarkup(new[]
        {
            new[]
            {
                InlineKeyboardButton.WithCallbackData($"JPG{mark(ScanFormat.Jpeg)}",  $"set:fmt:{sid}:jpeg"),
                InlineKeyboardButton.WithCallbackData($"PNG{mark(ScanFormat.Png)}",   $"set:fmt:{sid}:png"),
                InlineKeyboardButton.WithCallbackData($"TIFF{mark(ScanFormat.Tiff)}", $"set:fmt:{sid}:tiff"),
            },
            new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"cancel:{sid}") },
        });
    }

    private static InlineKeyboardMarkup RenderDpiPicker(BotSession s)
    {
        var sid = s.DaemonSessionId;
        var cur = s.Params.Dpi;
        string label(int d) => d == cur ? $"{d} ✓" : $"{d}";
        return new InlineKeyboardMarkup(new[]
        {
            NativeDpis.Select(d =>
                InlineKeyboardButton.WithCallbackData(label(d), $"set:dpi:{sid}:{d}")).ToArray(),
            new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"cancel:{sid}") },
        });
    }
}
