namespace PrintScan.TelegramBot;

/// <summary>
/// Tiny shared UI helpers — used both by the scanner status line
/// (BotState.cs) and the printer's in-flight stage rendering
/// (PrintState.cs). Lives here rather than duplicated so the two
/// progress bars stay visually identical: same glyphs, same width,
/// same clamping rules.
/// </summary>
internal static class BotUiBits
{
    /// 10-segment progress bar, ▰ filled / ▱ empty — monospaced in
    /// Telegram, reads cleanly across desktop and mobile clients.
    /// Caps at 10/10 even if the caller's estimate reports >100
    /// (shouldn't, but be defensive).
    public static string ProgressBar(int pct)
    {
        var filled = System.Math.Clamp(pct / 10, 0, 10);
        return new string('▰', filled) + new string('▱', 10 - filled);
    }
}
