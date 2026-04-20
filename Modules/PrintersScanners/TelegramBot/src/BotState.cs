using PrintScan.Shared;
using Telegram.Bot;
using Telegram.Bot.Types;
using Telegram.Bot.Types.Enums;
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
    public required ScanParams Params { get; init; }
    public DateTimeOffset ExpiresAt { get; set; }
    public int ScanCount { get; set; }
    public bool ScannerOnline { get; set; }
    public bool Scanning { get; set; }
    public bool FirstScanPending { get; set; }   // auto-scan when scanner first appears
    public int LastUploadedSeq { get; set; }
}

/// <summary>
/// Composes the status-message body + inline keyboard shown to the user.
/// Pure function of <see cref="BotSession"/> state — call on every event.
/// </summary>
public static class StatusMessage
{
    public static (string Html, InlineKeyboardMarkup Keyboard) Render(BotSession s)
    {
        var remain = s.ExpiresAt - DateTimeOffset.UtcNow;
        var mins = remain.TotalSeconds < 0 ? 0 : (int)Math.Ceiling(remain.TotalMinutes);
        var fmt = s.Params.Format.ToString().ToUpperInvariant();

        var line1 = $"📷 <b>Session</b> · {s.Params.Dpi} dpi · {fmt} · {mins} min left";
        var line2 = (s.Scanning, s.ScannerOnline) switch
        {
            (true, _)      => "📡 Scanner: 📷 <i>scanning…</i>",
            (false, true)  => "📡 Scanner: ✅ ready — press its button or tap Scan",
            (false, false) => "📡 Scanner: ⏳ <i>waiting — power on or press its button</i>",
        };
        var line3 = $"📑 Scans delivered: <b>{s.ScanCount}</b>";

        var html = $"{line1}\n{line2}\n{line3}";

        var buttons = new List<InlineKeyboardButton[]>();
        if (!s.Scanning)
            buttons.Add([
                InlineKeyboardButton.WithCallbackData("📷 Scan now", $"scan:{s.DaemonSessionId}")
            ]);
        buttons.Add([
            InlineKeyboardButton.WithCallbackData("🚪 End session", $"end:{s.DaemonSessionId}")
        ]);
        return (html, new InlineKeyboardMarkup(buttons));
    }

    public static string RenderTerminated(BotSession s, SessionTerminationReason reason, string? newOwner)
    {
        var reasonText = reason switch
        {
            SessionTerminationReason.Timeout => "⏰ Session expired",
            SessionTerminationReason.Takeover => $"🚪 Session taken over by {newOwner ?? "another user"}",
            SessionTerminationReason.Closed => "🚪 Session ended",
            _ => "Session ended"
        };
        return $"{reasonText}\n📑 Final count: <b>{s.ScanCount}</b>";
    }
}

/// <summary>
/// Menu shown after /scan. User picks format + DPI before the session opens.
/// DPI list is the V33's native set (75 rounds to 100, so 75 is omitted).
/// </summary>
public static class ScanMenu
{
    public static readonly int[] NativeDpis = [100, 200, 300, 600, 1200];
    public const int DefaultDpi = 200;

    public static InlineKeyboardMarkup RenderFormat()
    {
        return new InlineKeyboardMarkup(
        [
            [InlineKeyboardButton.WithCallbackData("📄 JPG (default)", "open:jpeg")],
            [InlineKeyboardButton.WithCallbackData("🖼️ PNG (lossless)", "open:png")],
            [InlineKeyboardButton.WithCallbackData("🗄️ TIFF (archive)", "open:tiff")]
        ]);
    }

    public static InlineKeyboardMarkup RenderDpi(string format)
    {
        var rows = NativeDpis.Select(dpi =>
        {
            var label = dpi == DefaultDpi ? $"⭐ {dpi} dpi" : $"{dpi} dpi";
            return new[] { InlineKeyboardButton.WithCallbackData(label, $"dpi:{format}:{dpi}") };
        }).ToArray();
        return new InlineKeyboardMarkup(rows);
    }
}
