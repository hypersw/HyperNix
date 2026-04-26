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
    /// Message id of the *current* live session message. Mutable
    /// on purpose: every time the user posts a new file the bot
    /// abandons the previous live message (replacing its body
    /// with "→ continued below ↓", removing the keyboard) and
    /// sends a fresh one positioned right under the user's
    /// upload, so the active session UI stays in view instead
    /// of scrolling away.
    public int StatusMessageId { get; set; }
    /// Type of the current live message. Toggle/confirm/cancel
    /// edits use editMessageMedia / editMessageCaption / editMessageText
    /// depending on this — Telegram's edit verbs don't transparently
    /// span message types. Set on every message-handover.
    public LiveMessageKind StatusKind { get; set; } = LiveMessageKind.Text;
    public bool PrinterOnline { get; set; } = true;
    /// Paper size as reported by the daemon at session open. Drives
    /// "1:1 fits?" logic and (eventually) preview rendering geometry.
    /// Falls back to A4 when the daemon doesn't know.
    public string MediaSize { get; set; } = "A4";
    /// Non-printable margins as reported by the daemon. Used together
    /// with MediaSize to compute the safe printable rectangle for
    /// the "1:1 fits?" check.
    public PrintableMargins Margins { get; set; } = new();

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

    /// Total page count for pageables (PDFs and rendered docs);
    /// null when unknown (not yet queried, not a PDF, or pdfinfo
    /// failed). Drives the per-page checkbox UI for short PDFs.
    public int? PageCount { get; set; }

    /// Custom page-range expression in CUPS notation
    /// (e.g. "1-3,5,7-9"). Empty string means "no custom range
    /// active". Constructed via the digit-keyboard picker; takes
    /// precedence over <see cref="PageSelection"/> when non-empty.
    public string PageRange { get; set; } = "";

    /// Percent of the physical page area the source image's content
    /// would occupy, computed by <see cref="PrintPreview"/> when the
    /// preview is rendered. Surfaces the "is this going to print
    /// postmark-sized?" answer in the caption — populated for
    /// images, null otherwise.
    public double? PreviewFillPercent { get; set; }

    /// True when the user uploaded this as a Telegram Photo (compressed
    /// in transit) rather than as a Document. The bot doesn't *block*
    /// the upload — sometimes you legitimately want to forward a
    /// channel post — but the UI annotates it so the user has a chance
    /// to back out and resend as a file.
    public bool TelegramCompressed { get; set; }

    public const int MinReasonableDpi = 100;
    /// Tolerance for the "1:1 fits?" check. A 1 mm slop catches
    /// rounding-error overflows on otherwise page-sized scans
    /// without classifying them as "won't fit".
    public const double FitSlopMm = 1.0;
    private const double InchesPerMm = 1.0 / 25.4;

    /// Paper short side in inches — set at staging time from the
    /// session's <see cref="BotPrintSession.MediaSize"/>. Drives the
    /// "1:1 fits?" check and (eventually) preview rendering.
    public required double PaperShortInches { get; init; }
    public required double PaperLongInches  { get; init; }
    /// Printer's safe printable rectangle (paper minus non-printable
    /// margins) in inches. Set at staging time from the session's
    /// margins config.
    public required double PrintableShortInches { get; init; }
    public required double PrintableLongInches  { get; init; }

    /// Three-state classification of how 1:1 printing would land
    /// on the page — drives the badge on the 1:1 scale button so
    /// the user can pick it knowingly even when the image overflows.
    public OneToOneFit Fits1to1
    {
        get
        {
            if (Kind != PendingPrintKind.Image) return OneToOneFit.NotApplicable;
            if (Dpi is not int d || d < MinReasonableDpi) return OneToOneFit.NotApplicable;
            if (PixelWidth is not int w || PixelHeight is not int h)
                return OneToOneFit.NotApplicable;
            var shortIn = Math.Min(w, h) / (double)d;
            var longIn  = Math.Max(w, h) / (double)d;
            var slopIn = FitSlopMm * InchesPerMm;
            if (shortIn <= PrintableShortInches + slopIn &&
                longIn  <= PrintableLongInches  + slopIn)
                return OneToOneFit.Printable;
            if (shortIn <= PaperShortInches + slopIn &&
                longIn  <= PaperLongInches  + slopIn)
                return OneToOneFit.PaperFitsMarginsClipped;
            return OneToOneFit.Overflows;
        }
    }

    /// Pick the orientation we'd like to default to when the user
    /// hasn't picked one explicitly — the longer image dimension
    /// goes on the longer page dimension.
    public PrintOrientation AutoSuggestedOrientation =>
        PixelWidth is int w && PixelHeight is int h && w > h
            ? PrintOrientation.Landscape
            : PrintOrientation.Portrait;
}

/// <summary>
/// Outcome of comparing an image's 1:1 physical size against the
/// printable area. <see cref="Printable"/> means the image fits
/// inside the printer's safe area (with a small slop tolerance);
/// <see cref="PaperFitsMarginsClipped"/> means it fits the paper
/// but would have edges chopped by the non-printable margin;
/// <see cref="Overflows"/> means it exceeds the paper itself.
/// </summary>
public enum OneToOneFit
{
    NotApplicable,
    Printable,
    PaperFitsMarginsClipped,
    Overflows,
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
/// Type of the current live-session Telegram message — drives the
/// edit verb the bot uses on the next refresh.
/// </summary>
public enum LiveMessageKind
{
    /// Plain text — used at session open before any file lands.
    /// Subsequent edits go through editMessageText.
    Text,
    /// Photo (used for image previews and short-pageable previews).
    /// Edits go through editMessageMedia (for the preview image)
    /// or editMessageCaption (for caption-only updates like
    /// "Printing…" / "Done").
    Photo,
    /// Document — used when we send a Pageable (PDF) for the user
    /// to verify before printing. Edits go through editMessageCaption.
    /// editMessageMedia on a Document also works but we don't
    /// need it because the document itself doesn't change with
    /// scale/orient/range toggles.
    Document,
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
    PageRangeKeyboard,
}

/// <summary>
/// Parser/serializer for CUPS page-range notation
/// (e.g. "1-3,5,7-9"). Used both by the per-page checkbox UI
/// (toggle ↔ string conversion) and by the digit-keyboard custom-
/// range picker (display only, no structural parsing).
/// </summary>
public static class PageRangeNotation
{
    public static HashSet<int> Parse(string range, int maxPage)
    {
        var pages = new HashSet<int>();
        if (string.IsNullOrWhiteSpace(range)) return pages;
        foreach (var raw in range.Split(','))
        {
            var part = raw.Trim();
            if (part.Length == 0) continue;
            var dashIdx = part.IndexOf('-');
            if (dashIdx < 0)
            {
                if (int.TryParse(part, out var p) && p >= 1 && p <= maxPage)
                    pages.Add(p);
            }
            else
            {
                var lo = part[..dashIdx].Trim();
                var hi = part[(dashIdx + 1)..].Trim();
                int from = int.TryParse(lo, out var lv) ? lv : 1;
                int to   = int.TryParse(hi, out var rv) ? rv : maxPage;
                for (int i = Math.Max(1, from); i <= Math.Min(maxPage, to); i++)
                    pages.Add(i);
            }
        }
        return pages;
    }

    public static string Serialize(IEnumerable<int> pages)
    {
        var sorted = pages.Where(p => p > 0).Distinct().OrderBy(p => p).ToList();
        if (sorted.Count == 0) return "";
        var parts = new List<string>();
        int start = sorted[0], prev = sorted[0];
        for (int i = 1; i <= sorted.Count; i++)
        {
            if (i == sorted.Count || sorted[i] != prev + 1)
            {
                parts.Add(start == prev ? start.ToString() : $"{start}-{prev}");
                if (i < sorted.Count) { start = sorted[i]; prev = sorted[i]; }
            }
            else
            {
                prev = sorted[i];
            }
        }
        return string.Join(",", parts);
    }
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
            PrintPickerView.Scale             => RenderScalePicker(s),
            PrintPickerView.Orientation       => RenderOrientPicker(s),
            PrintPickerView.Pages             => RenderPagesPicker(s),
            PrintPickerView.PageRangeKeyboard => RenderPageRangeKeyboard(s),
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
            // Echo the current page-range buffer above the digit
            // keyboard so the user sees what they're typing.
            if (s.View == PrintPickerView.PageRangeKeyboard)
            {
                var buf = string.IsNullOrEmpty(p.PageRange) ? "(empty)" : p.PageRange;
                lines.Add("");
                lines.Add($"<b>Range:</b> <code>{EscapeHtml(buf)}</code>");
            }
        }
        else
        {
            lines.Add("");
            lines.Add("Send a PDF / PostScript / image / Markdown / Office doc to print " +
                "(tap 📎 in the chat composer below).");
        }

        return string.Join("\n", lines);
    }

    private static string RenderPendingBlock(PendingPrint p)
    {
        var icon = p.Kind == PendingPrintKind.Image ? "🖼" : "📄";
        var sizeKb = p.Data.Length / 1024;
        var sizeText = sizeKb < 1024
            ? $"{sizeKb} KB"
            : $"{sizeKb / 1024.0:F1} MB";
        var head = $"{icon} <b>{EscapeHtml(p.FileName)}</b> · {sizeText}";

        if (p.Kind != PendingPrintKind.Image)
        {
            var pageInfo = p.PageCount is int pc ? $" · {pc} page{(pc == 1 ? "" : "s")}" : "";
            // Hide the Pages line entirely for single-page docs —
            // there's only one option, no need to mention it.
            var pagesLine = (p.PageCount is int pc2 && pc2 == 1)
                ? ""
                : $"\nPages: <b>{PagesEffectiveLabel(p)}</b>";
            return $"{head}{pageInfo}{pagesLine}\nReady to print?";
        }

        var dims = (p.PixelWidth, p.PixelHeight) switch
        {
            (int w, int h) => $"{w}×{h} px",
            _ => "unknown size",
        };
        var dpi = p.Dpi is int d ? $" @ {d} dpi" : "";

        var effectiveOrient = p.Orientation == PrintOrientation.Auto
            ? p.AutoSuggestedOrientation
            : p.Orientation;
        var orientText = p.Orientation == PrintOrientation.Auto
            ? $"auto ({effectiveOrient.ToString().ToLower()})"
            : effectiveOrient.ToString().ToLower();

        // Render the 1:1-fit caveat when the user has picked it
        // explicitly and it would clip or overflow — they should know
        // before tapping ✅.
        var scaleText = ScaleLabel(p.Scale);
        if (p.Scale == PrintScaleMode.OneToOne)
        {
            scaleText += p.Fits1to1 switch
            {
                OneToOneFit.PaperFitsMarginsClipped =>
                    " <i>(edges into non-printable margin)</i>",
                OneToOneFit.Overflows =>
                    " <i>(exceeds page — will be cropped)</i>",
                _ => "",
            };
        }

        // Page-fill % from the preview compositor — answers the
        // "would it land postmark-sized?" question quantitatively.
        var fillSuffix = p.PreviewFillPercent is double fp
            ? $" · fills <b>{fp:F0}%</b> of page"
            : "";
        // Telegram-compressed warning: user uploaded as a Photo
        // (which TG transcodes) rather than as a Document. Print
        // anyway — they may have meant to forward a chat photo —
        // but make the trade-off visible.
        var compressedWarn = p.TelegramCompressed
            ? "\n⚠ <i>Sent as Telegram media (compressed). Resend as a file for full quality.</i>"
            : "";

        return
            $"{head} · {dims}{dpi}{fillSuffix}\n" +
            $"Scale: <b>{scaleText}</b>" +
            $" · Orientation: <b>{orientText}</b>" +
            compressedWarn +
            "\nReady to print?";
    }

    private static string PagesEffectiveLabel(PendingPrint p) =>
        string.IsNullOrEmpty(p.PageRange)
            ? PagesLabel(p.PageSelection)
            : p.PageRange;

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

        // Pages selector — only meaningful for documents with more
        // than one page. Hide it for images (always single-page) and
        // for single-page PDFs so the UI doesn't offer "Odd / Even"
        // as if there were multiple sheets to choose from.
        bool showPages =
            p.Kind == PendingPrintKind.Pageable &&
            (p.PageCount is null || p.PageCount.Value > 1);
        if (showPages)
        {
            rows.Add(new[]
            {
                InlineKeyboardButton.WithCallbackData($"📑 Pages: {PagesEffectiveLabel(p)}",
                    $"print:pick:pages:{p.Id}"),
            });
        }

        rows.Add(new[]
        {
            InlineKeyboardButton.WithCallbackData("✅ Print",  $"print:confirm:{p.Id}"),
            InlineKeyboardButton.WithCallbackData("❌ Cancel", $"print:cancel:{p.Id}"),
        });
        return new InlineKeyboardMarkup(rows);
    }

    private const string SelectedMark   = "🔘 ";
    private const string UnselectedMark = "⚪ ";
    private const string CheckedMark    = "☑ ";
    private const string UncheckedMark  = "☐ ";

    private static InlineKeyboardMarkup RenderScalePicker(BotPrintSession s)
    {
        if (s.Pending is null)
            return new InlineKeyboardMarkup(new[] {
                new[] { InlineKeyboardButton.WithCallbackData("↩ back", "print:pick:main:_") }
            });

        var p = s.Pending;
        string mark(PrintScaleMode m) => p.Scale == m ? SelectedMark : UnselectedMark;
        // 1:1 is always offered now — even when the image overflows
        // the printable area or the page itself, the user may know
        // something we don't (paper they actually loaded, willingness
        // to crop). The badge tells them what'll happen, including
        // an explicit positive ✓ when 1:1 fits — the previous "no
        // badge" rendering was ambiguous (does silence mean "fits"
        // or "no info"?).
        var oneOneLabel = "1:1" + p.Fits1to1 switch
        {
            OneToOneFit.Printable               => " ✓",
            OneToOneFit.PaperFitsMarginsClipped => " ⚠ margins",
            OneToOneFit.Overflows               => " ⚠ won't fit",
            _ => "",
        };
        var rows = new List<InlineKeyboardButton[]>();
        var row = new List<InlineKeyboardButton>
        {
            InlineKeyboardButton.WithCallbackData(
                $"{mark(PrintScaleMode.OneToOne)}{oneOneLabel}",
                $"print:set:scale:{p.Id}:onetoone"),
            InlineKeyboardButton.WithCallbackData(
                $"{mark(PrintScaleMode.Fit)}Fit",  $"print:set:scale:{p.Id}:fit"),
            InlineKeyboardButton.WithCallbackData(
                $"{mark(PrintScaleMode.Fill)}Fill", $"print:set:scale:{p.Id}:fill"),
        };
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

    /// Soft cap for the per-page checkbox UI: we display individual
    /// per-page checkboxes when the document has at most this many
    /// pages. Above this, fall back to the digit-keyboard custom
    /// range view (no chat-text-input flow needed).
    public const int PerPageCheckboxCap = 10;

    private static InlineKeyboardMarkup RenderPagesPicker(BotPrintSession s)
    {
        if (s.Pending is null)
            return new InlineKeyboardMarkup(new[] {
                new[] { InlineKeyboardButton.WithCallbackData("↩ back", "print:pick:main:_") }
            });

        var p = s.Pending;
        string radio(PageSelection sel) =>
            (string.IsNullOrEmpty(p.PageRange) && p.PageSelection == sel)
                ? SelectedMark : UnselectedMark;

        var rows = new List<InlineKeyboardButton[]>();

        // Top row: All / Odd / Even radio (zeros out PageRange).
        rows.Add(new[]
        {
            InlineKeyboardButton.WithCallbackData($"{radio(PageSelection.All)}All",
                $"print:set:pages:{p.Id}:all"),
            InlineKeyboardButton.WithCallbackData($"{radio(PageSelection.Odd)}Odd",
                $"print:set:pages:{p.Id}:odd"),
            InlineKeyboardButton.WithCallbackData($"{radio(PageSelection.Even)}Even",
                $"print:set:pages:{p.Id}:even"),
        });

        // Per-page checkboxes when we know the count and it's small
        // enough to fit two rows of five buttons. Tapping a page
        // toggles it in PageRange (overrides the All/Odd/Even radio
        // — non-empty PageRange wins).
        if (p.PageCount is int pc && pc > 0 && pc <= PerPageCheckboxCap)
        {
            var selected = PageRangeNotation.Parse(p.PageRange, pc);
            // If PageRange is empty, derive selection from the
            // radio so the checkboxes mirror what would actually
            // print today.
            if (selected.Count == 0 && string.IsNullOrEmpty(p.PageRange))
            {
                for (int i = 1; i <= pc; i++)
                {
                    var include = p.PageSelection switch
                    {
                        PageSelection.Odd  => i % 2 == 1,
                        PageSelection.Even => i % 2 == 0,
                        _ => true,
                    };
                    if (include) selected.Add(i);
                }
            }
            for (int rowStart = 1; rowStart <= pc; rowStart += 5)
            {
                var row = new List<InlineKeyboardButton>();
                for (int i = rowStart; i < rowStart + 5 && i <= pc; i++)
                {
                    var glyph = selected.Contains(i) ? CheckedMark : UncheckedMark;
                    row.Add(InlineKeyboardButton.WithCallbackData(
                        $"{glyph}{i}", $"print:togglepage:{p.Id}:{i}"));
                }
                rows.Add(row.ToArray());
            }
        }

        // Custom-range entry — opens the digit keyboard.
        rows.Add(new[]
        {
            InlineKeyboardButton.WithCallbackData(
                "✏ Custom range" + (string.IsNullOrEmpty(p.PageRange) ? "" : ": " + p.PageRange),
                $"print:pick:rangekb:{p.Id}"),
        });

        rows.Add(new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"print:pick:main:{p.Id}") });
        return new InlineKeyboardMarkup(rows);
    }

    /// <summary>
    /// Per-button "type" UI for entering a custom page-range
    /// expression, since Telegram bot inline keyboards don't have a
    /// native text-input affordance. Each digit/comma/dash button
    /// appends one character to PendingPrint.PageRange; ⌫ pops one;
    /// ↺ clears; ✓ applies and returns to the main view.
    /// </summary>
    private static InlineKeyboardMarkup RenderPageRangeKeyboard(BotPrintSession s)
    {
        if (s.Pending is null)
            return new InlineKeyboardMarkup(new[] {
                new[] { InlineKeyboardButton.WithCallbackData("↩ back", "print:pick:main:_") }
            });
        var p = s.Pending;
        InlineKeyboardButton key(string label, string value) =>
            InlineKeyboardButton.WithCallbackData(label, $"print:rangekey:{p.Id}:{value}");

        return new InlineKeyboardMarkup(new[]
        {
            new[] { key("1", "1"), key("2", "2"), key("3", "3"), key("4", "4"), key("5", "5") },
            new[] { key("6", "6"), key("7", "7"), key("8", "8"), key("9", "9"), key("0", "0") },
            new[] { key("-", "-"), key(",", ","), key("⌫", "BS"), key("↺", "CLR"), key("✓", "OK") },
            new[] { InlineKeyboardButton.WithCallbackData("↩ back", $"print:pick:pages:{p.Id}") },
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
