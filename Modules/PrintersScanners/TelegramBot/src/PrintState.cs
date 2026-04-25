using PrintScan.Shared;
using Telegram.Bot.Types.ReplyMarkups;

namespace PrintScan.TelegramBot;

/// <summary>
/// Per-chat printer-session state. Printing isn't an exclusive
/// resource the way scanning is (multiple users can submit jobs to
/// CUPS in parallel), so each chat keeps its own session — there's
/// no daemon-side global lock, no takeover handshake, no SSE primer.
/// State lives only in the bot process; bot crash → user re-sends.
/// </summary>
public sealed class BotPrintSession
{
    public required long ChatId { get; init; }
    public required int StatusMessageId { get; init; }
    public bool PrinterOnline { get; set; } = true;
    /// Paper size as reported by the daemon at session open. Drives
    /// "1:1 fits?" logic and (eventually) preview rendering geometry.
    /// Falls back to A4 when the daemon doesn't know.
    public string MediaSize { get; set; } = "A4";

    /// The file the user has staged but not yet confirmed (or null
    /// when the session is idle). Holding the bytes in memory bounds
    /// the worst case to one document per chat — released on Confirm
    /// (after upload) or Cancel.
    public PendingPrint? Pending { get; set; }

    /// True while a confirmed job is in flight to the daemon. Blocks
    /// re-entrancy from a second confirm tap and tells the renderer
    /// to swap the keyboard out for a "printing…" caption.
    public bool Printing { get; set; }

    /// Last few completed jobs, newest-first. Trimmed at
    /// <see cref="HistoryCap"/> so the session message doesn't grow
    /// unboundedly.
    public List<PrintHistoryEntry> History { get; } = new();
    public const int HistoryCap = 5;

    public PrintPickerView View { get; set; } = PrintPickerView.Main;
}

/// <summary>
/// One file the user uploaded that's awaiting "Print" or "Cancel".
/// The Id is opaque, regenerated each time a new file arrives — used
/// in callback-data so a stale tap on a previous pending's button
/// doesn't act on the current one.
/// </summary>
public sealed class PendingPrint
{
    public required string Id { get; init; }
    public required byte[] Data { get; init; }
    public required string FileName { get; init; }
    public required string ContentType { get; init; }
    public required PendingPrintKind Kind { get; init; }
    public int? PixelWidth { get; init; }
    public int? PixelHeight { get; init; }
    /// Image dpi from the file's metadata, when present and ≥ minimum
    /// for "1:1 makes sense" (see <see cref="MinReasonableDpi"/>).
    public int? Dpi { get; init; }
    public PrintScaleMode Scale { get; set; } = PrintScaleMode.Fit;
    public PrintOrientation Orientation { get; set; } = PrintOrientation.Auto;
    public PageSelection PageSelection { get; set; } = PageSelection.All;

    public const int MinReasonableDpi = 100;

    /// Paper short side in inches — set at staging time from the
    /// session's <see cref="BotPrintSession.MediaSize"/>. Drives the
    /// "1:1 fits?" check and (eventually) preview rendering.
    public required double PaperShortInches { get; init; }
    public required double PaperLongInches  { get; init; }

    /// True when the image's native dimensions, at its declared dpi,
    /// fit on the configured paper size in either orientation. Drives
    /// whether 1:1 is offered as a scale option.
    public bool Fits1to1 =>
        Kind == PendingPrintKind.Image &&
        Dpi is int d && d >= MinReasonableDpi &&
        PixelWidth is int w && PixelHeight is int h &&
        Math.Min(w, h) / (double)d <= PaperShortInches &&
        Math.Max(w, h) / (double)d <= PaperLongInches;

    /// Pick the orientation we'd like to default to when the user
    /// hasn't picked one explicitly — the longer image dimension
    /// goes on the longer page dimension.
    public PrintOrientation AutoSuggestedOrientation =>
        PixelWidth is int w && PixelHeight is int h && w > h
            ? PrintOrientation.Landscape
            : PrintOrientation.Portrait;
}

public enum PendingPrintKind
{
    /// Pre-paginated print-native (PDF, PostScript). No scale/orient
    /// pickers in the UI — the document already has its own page
    /// geometry.
    Pageable,
    /// Raster image — bot offers scale (1:1/Fit/Fill) and orientation.
    Image,
}

/// <summary>
/// Classifier output for an incoming file. Image and Pageable are
/// directly stageable; Renderable means we have to bounce it through
/// the rendering daemon (libreoffice → PDF) before it becomes a
/// Pageable PendingPrint.
/// </summary>
public enum IncomingFileKind
{
    Pageable,
    Image,
    Renderable,
    Unsupported,
}

public enum PrintPickerView
{
    Main,
    Scale,
    Orientation,
    Pages,
}

/// <summary>
/// Lookup of common paper sizes → physical short/long sides in inches.
/// Lives bot-side because the daemon is content-dumb (it only knows
/// the size's name) and it's the bot that needs to act on the geometry
/// for 1:1-fits and (later) preview rendering.
/// </summary>
public static class PaperSizes
{
    public static (double Short, double Long) Inches(string? name)
    {
        // Names come from the daemon's nix-module config, so casing
        // can vary; canonicalise.
        var key = (name ?? "A4").Trim().ToUpperInvariant();
        return key switch
        {
            "A4"     => (8.27, 11.69),
            "LETTER" => (8.5,  11.0),
            "LEGAL"  => (8.5,  14.0),
            "A3"     => (11.69, 16.54),
            "A5"     => (5.83,  8.27),
            _ => (8.27, 11.69), // unknown → assume A4
        };
    }
}

public record PrintHistoryEntry(
    DateTimeOffset At,
    string FileName,
    bool Success,
    string? Error = null);

/// <summary>
/// Renders the printer-session status message and its inline
/// keyboard. Mirrors <see cref="StatusMessage"/>'s shape for the
/// scanner session so callback-data parsing follows the same
/// "verb:what:sessionId[:value]" convention.
/// </summary>
public static class PrintMessage
{
    public static (string Html, InlineKeyboardMarkup? Keyboard) Render(
        BotPrintSession s, string botUsername)
    {
        var html = RenderHtml(s, botUsername);
        var kb = s.View switch
        {
            PrintPickerView.Scale       => RenderScalePicker(s),
            PrintPickerView.Orientation => RenderOrientPicker(s),
            PrintPickerView.Pages       => RenderPagesPicker(s),
            _ => RenderMain(s),
        };
        return (html, kb);
    }

    public static string RenderTerminated(BotPrintSession s)
    {
        var jobs = s.History.Count;
        return jobs == 0
            ? "🖨 Printer session ended."
            : $"🖨 Printer session ended · {jobs} job(s) printed.";
    }

    private static string RenderHtml(BotPrintSession s, string botUsername)
    {
        var status = s.PrinterOnline
            ? "🖨 Printer: ✅ ready"
            : "🖨 Printer: ⚠️ <i>offline</i>";

        var endLink = $"<a href=\"https://t.me/{botUsername}?start=printend\">end</a>";

        var lines = new List<string>
        {
            $"🖨 <b>Printer session</b> · {endLink}",
            status,
        };

        if (s.History.Count > 0)
        {
            // Most recent 3 — anything beyond that fits in History but
            // doesn't need to clutter the header.
            var summaries = s.History.Take(3).Select(h =>
                $"{(h.Success ? "✅" : "❌")} {EscapeHtml(h.FileName)}");
            lines.Add($"📑 Recent: {string.Join(" · ", summaries)}");
        }

        if (s.Printing)
        {
            lines.Add("");
            lines.Add($"⏳ <b>Printing</b> {EscapeHtml(s.Pending?.FileName ?? "…")}");
        }
        else if (s.Pending is { } p)
        {
            lines.Add("");
            lines.Add(RenderPendingBlock(p));
        }
        else
        {
            lines.Add("");
            lines.Add("Send a PDF / PostScript / image to print " +
                "(tap 📎 in the chat composer below).");
        }

        return string.Join("\n", lines);
    }

    private static string RenderPendingBlock(PendingPrint p)
    {
        var icon = p.Kind == PendingPrintKind.Image ? "🖼" : "📄";
        var sizeKb = p.Data.Length / 1024;
        var head = sizeKb < 1024
            ? $"{icon} <b>{EscapeHtml(p.FileName)}</b> · {sizeKb} KB"
            : $"{icon} <b>{EscapeHtml(p.FileName)}</b> · {sizeKb / 1024.0:F1} MB";

        if (p.Kind != PendingPrintKind.Image)
            return $"{head}\nReady to print?";

        var dims = (p.PixelWidth, p.PixelHeight) switch
        {
            (int w, int h) => $"{w}×{h} px",
            _ => "unknown size",
        };
        var dpi = p.Dpi is int d ? $" @ {d} dpi" : "";

        // The auto orientation gets resolved here purely for display
        // — the wire value we send the daemon stays "Auto" so the
        // suggestion doesn't get baked in, but the user sees what
        // we'd actually do.
        var effectiveOrient = p.Orientation == PrintOrientation.Auto
            ? p.AutoSuggestedOrientation
            : p.Orientation;
        var orientText = p.Orientation == PrintOrientation.Auto
            ? $"auto ({effectiveOrient.ToString().ToLower()})"
            : effectiveOrient.ToString().ToLower();

        return
            $"{head} · {dims}{dpi}\n" +
            $"Scale: <b>{ScaleLabel(p.Scale)}</b>" +
            (p.Kind == PendingPrintKind.Image ? $" · Orientation: <b>{orientText}</b>" : "") +
            $" · Pages: <b>{PagesLabel(p.PageSelection)}</b>" +
            "\nReady to print?";
    }

    private static string PagesLabel(PageSelection sel) => sel switch
    {
        PageSelection.All  => "all",
        PageSelection.Odd  => "odd only",
        PageSelection.Even => "even only",
        _ => sel.ToString(),
    };

    private static InlineKeyboardMarkup? RenderMain(BotPrintSession s)
    {
        // Idle session (no pending, not printing): nothing actionable
        // beyond the deep-link "end" in the header. Returning null
        // strips the inline keyboard entirely; the persistent reply
        // keyboard at chat level still has [📎 paperclip cue].
        if (s.Pending is null || s.Printing) return null;

        var p = s.Pending;
        var rows = new List<InlineKeyboardButton[]>();

        // Image-only: scale + orientation pickers above the action row.
        if (p.Kind == PendingPrintKind.Image)
        {
            rows.Add(new[]
            {
                InlineKeyboardButton.WithCallbackData($"📐 Scale: {ScaleLabel(p.Scale)}",
                    $"print:pick:scale:{p.Id}"),
                InlineKeyboardButton.WithCallbackData($"🧭 Orient: {OrientLabel(p.Orientation, p)}",
                    $"print:pick:orient:{p.Id}"),
            });
        }

        // Pages selector applies to both Pageable and Image inputs —
        // odd/even is occasionally useful even on a one-image scan
        // when chained into a manual duplex sequence with a second
        // sheet, though the common use is "skip blank trailing pages
        // on a multi-page PDF".
        rows.Add(new[]
        {
            InlineKeyboardButton.WithCallbackData($"📑 Pages: {PagesLabel(p.PageSelection)}",
                $"print:pick:pages:{p.Id}"),
        });

        rows.Add(new[]
        {
            InlineKeyboardButton.WithCallbackData("✅ Print",  $"print:confirm:{p.Id}"),
            InlineKeyboardButton.WithCallbackData("❌ Cancel", $"print:cancel:{p.Id}"),
        });
        return new InlineKeyboardMarkup(rows);
    }

    private const string SelectedMark   = "🔘 ";
    private const string UnselectedMark = "⚪ ";

    private static InlineKeyboardMarkup RenderScalePicker(BotPrintSession s)
    {
        // Defensive: if user toggles into the picker but the pending
        // got dropped (e.g., session timed out), fall back to a back
        // button so the UI doesn't hang.
        if (s.Pending is null)
            return new InlineKeyboardMarkup(new[] {
                new[] { InlineKeyboardButton.WithCallbackData("↩ back", "print:pick:main:_") }
            });

        var p = s.Pending;
        string mark(PrintScaleMode m) => p.Scale == m ? SelectedMark : UnselectedMark;
        var rows = new List<InlineKeyboardButton[]>();
        var row = new List<InlineKeyboardButton>();
        if (p.Fits1to1)
            row.Add(InlineKeyboardButton.WithCallbackData(
                $"{mark(PrintScaleMode.OneToOne)}1:1", $"print:set:scale:{p.Id}:onetoone"));
        row.Add(InlineKeyboardButton.WithCallbackData(
            $"{mark(PrintScaleMode.Fit)}Fit", $"print:set:scale:{p.Id}:fit"));
        row.Add(InlineKeyboardButton.WithCallbackData(
            $"{mark(PrintScaleMode.Fill)}Fill", $"print:set:scale:{p.Id}:fill"));
        rows.Add(row.ToArray());
        rows.Add(new[] {
            InlineKeyboardButton.WithCallbackData("↩ back", $"print:pick:main:{p.Id}")
        });
        return new InlineKeyboardMarkup(rows);
    }

    private static InlineKeyboardMarkup RenderOrientPicker(BotPrintSession s)
    {
        if (s.Pending is null)
            return new InlineKeyboardMarkup(new[] {
                new[] { InlineKeyboardButton.WithCallbackData("↩ back", "print:pick:main:_") }
            });

        var p = s.Pending;
        string mark(PrintOrientation o) => p.Orientation == o ? SelectedMark : UnselectedMark;
        return new InlineKeyboardMarkup(new[]
        {
            new[]
            {
                InlineKeyboardButton.WithCallbackData(
                    $"{mark(PrintOrientation.Auto)}Auto",      $"print:set:orient:{p.Id}:auto"),
                InlineKeyboardButton.WithCallbackData(
                    $"{mark(PrintOrientation.Portrait)}Portrait",  $"print:set:orient:{p.Id}:portrait"),
                InlineKeyboardButton.WithCallbackData(
                    $"{mark(PrintOrientation.Landscape)}Landscape", $"print:set:orient:{p.Id}:landscape"),
            },
            new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"print:pick:main:{p.Id}") },
        });
    }

    private static InlineKeyboardMarkup RenderPagesPicker(BotPrintSession s)
    {
        if (s.Pending is null)
            return new InlineKeyboardMarkup(new[] {
                new[] { InlineKeyboardButton.WithCallbackData("↩ back", "print:pick:main:_") }
            });

        var p = s.Pending;
        string mark(PageSelection sel) => p.PageSelection == sel ? SelectedMark : UnselectedMark;
        return new InlineKeyboardMarkup(new[]
        {
            new[]
            {
                InlineKeyboardButton.WithCallbackData($"{mark(PageSelection.All)}All",
                    $"print:set:pages:{p.Id}:all"),
                InlineKeyboardButton.WithCallbackData($"{mark(PageSelection.Odd)}Odd",
                    $"print:set:pages:{p.Id}:odd"),
                InlineKeyboardButton.WithCallbackData($"{mark(PageSelection.Even)}Even",
                    $"print:set:pages:{p.Id}:even"),
            },
            new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"print:pick:main:{p.Id}") },
        });
    }

    private static string ScaleLabel(PrintScaleMode m) => m switch
    {
        PrintScaleMode.OneToOne => "1:1",
        PrintScaleMode.Fit      => "Fit",
        PrintScaleMode.Fill     => "Fill",
        _ => m.ToString(),
    };

    private static string OrientLabel(PrintOrientation o, PendingPrint p) => o switch
    {
        PrintOrientation.Auto      => $"auto ({p.AutoSuggestedOrientation.ToString().ToLower()})",
        PrintOrientation.Portrait  => "portrait",
        PrintOrientation.Landscape => "landscape",
        _ => o.ToString(),
    };

    private static string EscapeHtml(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
}
