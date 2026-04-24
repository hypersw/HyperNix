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
    // 0..100 while a scan is in flight; null / 0 otherwise. Fed by
    // SessionScanProgress SSE events from the daemon; rendered as an
    // emoji bar next to the "scanning…" line in the status message.
    public int ScanProgress { get; set; }
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
        BotSession s, string botUsername, PickerView view = PickerView.Main)
    {
        var html = RenderHtml(s, botUsername);
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

    private static string RenderHtml(BotSession s, string botUsername)
    {
        var remain = s.ExpiresAt - DateTimeOffset.UtcNow;
        var mins = remain.TotalSeconds < 0 ? 0 : (int)Math.Ceiling(remain.TotalMinutes);

        var scannerLine = (s.Scanning, s.ScannerOnline) switch
        {
            (true, _)      => $"📡 Scanner: 📷 <i>scanning… {ProgressBar(s.ScanProgress)} {s.ScanProgress}%</i>",
            (false, true)  => "📡 Scanner: ✅ ready — tap Scan (or press scanner button)",
            (false, false) => "📡 Scanner: ⏳ <i>waiting — power on or press scanner button</i>",
        };

        // "end" rendered as a hyperlink deep-link instead of a keyboard
        // button. Tapping it navigates to `t.me/<bot>?start=end_<sid>`,
        // which inside this chat triggers /start end_<sid> on our bot;
        // the message handler recognises the payload, closes the session,
        // and deletes the user's /start message to keep the chat clean.
        // Keeps the Scan button big and alone on its row.
        var endLink = $"<a href=\"https://t.me/{botUsername}?start=end_{s.DaemonSessionId}\">end</a>";

        return $"""
            📷 <b>Scanner session</b> · {mins} min left · {endLink}
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
        // Row 1: tap-to-change parameter buttons; button labels carry
        // what was previously duplicated in the body text.
        rows.Add(new[]
        {
            InlineKeyboardButton.WithCallbackData($"📄 Format: {fmt}",              $"pick:fmt:{sid}"),
            InlineKeyboardButton.WithCallbackData($"📏 Resolution: {s.Params.Dpi} dpi", $"pick:dpi:{sid}"),
        });
        // Row 2: the primary-action button. Always present (was previously
        // omitted during scans, which made the keyboard reshape every time
        // a scan started/finished — jarring). Idle vs scanning differ only
        // in label and callback target:
        //   idle     → "📷 SCAN NOW!" (ALL CAPS stands in for bold — Telegram
        //              inline-button labels are plain text only, no HTML)
        //   scanning → "⏳ Scanning…" with callback data "noop". HandleCallback
        //              answers the query up-front then falls through on any
        //              unknown prefix, so a tap does nothing silently.
        rows.Add(s.Scanning
            ? new[] { InlineKeyboardButton.WithCallbackData("⏳ Scanning…", "noop") }
            : new[] { InlineKeyboardButton.WithCallbackData("📷 SCAN NOW!", $"scan:{sid}") });
        return new InlineKeyboardMarkup(rows);
    }

    // Progress bar for the in-flight scan status line. 10 segments,
    // ▰ filled / ▱ empty — monospaced in Telegram, reads cleanly
    // across desktop and mobile clients. Caps at 10/10 even if the
    // daemon's estimate reports >100 (shouldn't, but be defensive).
    private static string ProgressBar(int pct)
    {
        var filled = Math.Clamp(pct / 10, 0, 10);
        return new string('▰', filled) + new string('▱', 10 - filled);
    }

    // Radio-button emojis for current-selection indication in the
    // format / DPI pickers. The previous " ✓" suffix got lost next
    // to the emoji-heavy labels; filled-circle vs open-circle is
    // unambiguous at a glance and consistent across platforms.
    private const string SelectedMark   = "🔘 ";
    private const string UnselectedMark = "⚪ ";

    private static InlineKeyboardMarkup RenderFormatPicker(BotSession s)
    {
        var sid = s.DaemonSessionId;
        var cur = s.Params.Format;
        string mark(ScanFormat f) => f == cur ? SelectedMark : UnselectedMark;
        // Four format choices split 2+2 so a single row doesn't get
        // too cramped on narrow mobile widths.
        return new InlineKeyboardMarkup(new[]
        {
            new[]
            {
                InlineKeyboardButton.WithCallbackData($"{mark(ScanFormat.Jpeg)}JPG",  $"set:fmt:{sid}:jpeg"),
                InlineKeyboardButton.WithCallbackData($"{mark(ScanFormat.Png)}PNG",   $"set:fmt:{sid}:png"),
            },
            new[]
            {
                InlineKeyboardButton.WithCallbackData($"{mark(ScanFormat.Webp)}WEBP", $"set:fmt:{sid}:webp"),
                InlineKeyboardButton.WithCallbackData($"{mark(ScanFormat.Tiff)}TIFF", $"set:fmt:{sid}:tiff"),
            },
            new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"cancel:{sid}") },
        });
    }

    private static InlineKeyboardMarkup RenderDpiPicker(BotSession s)
    {
        var sid = s.DaemonSessionId;
        var cur = s.Params.Dpi;
        string label(int d) => d == cur ? $"{SelectedMark}{d}" : $"{UnselectedMark}{d}";
        return new InlineKeyboardMarkup(new[]
        {
            NativeDpis.Select(d =>
                InlineKeyboardButton.WithCallbackData(label(d), $"set:dpi:{sid}:{d}")).ToArray(),
            new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"cancel:{sid}") },
        });
    }
}
