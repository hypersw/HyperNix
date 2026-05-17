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

/// <summary>
/// Convert an ImageSharp metadata Horizontal/VerticalResolution pair
/// (which is the raw stored value — unit-dependent) into dpi (pixels
/// per inch). The PNG pHYs chunk's unit specifier byte is 0 (unspecified
/// → caller may treat as dpi) or 1 (pixels/meter); Windows screenshots
/// emit pHYs with unit=1 and value=3780 (= 96 dpi × 39.37 in/m), so a
/// naive "treat HorizontalResolution as dpi" reads "3780 dpi" instead
/// of "96 dpi". The misread propagated into the bot's 1:1-fit verdict
/// and the upscaler's pHYs stamp on the working image.
/// </summary>
internal static class ImageMetaDpi
{
    /// Returns dpi (≥ 0), or null when no usable resolution metadata
    /// is present. <paramref name="meta"/> is the
    /// SixLabors.ImageSharp.Metadata.ImageMetadata of an Identify or
    /// Load result.
    public static double? ReadMinDpi(SixLabors.ImageSharp.Metadata.ImageMetadata meta)
    {
        var hRes = meta.HorizontalResolution;
        var vRes = meta.VerticalResolution;
        if (hRes <= 0 || vRes <= 0) return null;
        var unit = meta.ResolutionUnits;
        // ImageSharp's PixelResolutionUnit:
        //   AspectRatio       — unitless; we can't say "dpi"
        //   PixelsPerInch     — value is already dpi
        //   PixelsPerCentimeter — multiply by 2.54
        //   PixelsPerMeter    — multiply by 0.0254
        var perInchH = unit switch
        {
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerInch       => hRes,
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerCentimeter => hRes * 2.54,
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerMeter      => hRes * 0.0254,
            _ => double.NaN,
        };
        var perInchV = unit switch
        {
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerInch       => vRes,
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerCentimeter => vRes * 2.54,
            SixLabors.ImageSharp.Metadata.PixelResolutionUnit.PixelsPerMeter      => vRes * 0.0254,
            _ => double.NaN,
        };
        if (double.IsNaN(perInchH) || double.IsNaN(perInchV)) return null;
        var minDpi = System.Math.Min(perInchH, perInchV);
        return minDpi > 0 ? minDpi : null;
    }
}
