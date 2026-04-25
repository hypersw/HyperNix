namespace PrintScan.Shared;

// ── Print ───────────────────────────────────────────────────────────────────

/// <summary>
/// How an image (or any rasterizable input) should be sized on the
/// physical page. Ignored for pre-paginated formats (PDF, PostScript)
/// where the document already encodes its own page geometry.
/// </summary>
public enum PrintScaleMode
{
    /// Print at native resolution (image px ÷ image dpi → physical
    /// inches). Only sensible when the dpi metadata is realistic and
    /// the resulting dimensions fit on the paper.
    OneToOne,
    /// Scale uniformly so the whole image fits within the printable
    /// area (no cropping; may leave margins).
    Fit,
    /// Scale uniformly so the image covers the printable area
    /// (no margins; crops the overflowing dimension).
    Fill,
}

public enum PrintOrientation
{
    /// Bot picks based on image aspect (longer side → page's longer side).
    Auto,
    Portrait,
    Landscape,
}

public record PrintRequest(
    string FileName,
    byte[] FileData,
    string? PageRange = null,
    int Copies = 1,
    PrintScaleMode Scale = PrintScaleMode.Fit,
    PrintOrientation Orientation = PrintOrientation.Auto
);

public record PrinterStatus(
    bool Online,
    string? StatusText = null
);

// ── Scan params ─────────────────────────────────────────────────────────────

/// <summary>
/// Parameters for one scan that the daemon actually acts on. Today
/// that's just dpi (passed through to scanimage). Anything client-
/// specific — format selection, encoder quality, output naming —
/// lives in the session's <see cref="SessionRecord.Metadata"/> bag
/// instead, so adding a new client never requires changing this type.
/// </summary>
public record ScanParams(
    int Dpi = 200
);

public record ScannerStatus(
    bool Online,
    string? StatusText = null
);

public record DeviceStatus(
    PrinterStatus Printer,
    ScannerStatus Scanner
);

// ── Session model ───────────────────────────────────────────────────────────

/// <summary>
/// Request body for <c>POST /sessions</c>. Bots send this to open a scan
/// session. <paramref name="Metadata"/> is an opaque key-value bag the
/// daemon stores and replays back via SSE without ever interpreting it
/// — clients use it for their own settings (e.g. the Telegram bot
/// stashes its format-selection bitmask there so the choice survives
/// a bot restart).
/// </summary>
public record OpenSessionRequest(
    string OwnerBot,            // "telegram", "whatsapp", "web", …
    long OwnerChatId,            // bot-specific; for TG this is the chat id
    int OwnerStatusMessageId,    // bot-side id of the status message to edit
    string OwnerDisplayName,     // free-form, for takeover notifications
    ScanParams Params,
    Dictionary<string, string>? Metadata = null
);

/// <summary>
/// Durable session record, persisted to disk on every mutation. Single source
/// of truth — bots reconstruct their view from events on startup.
/// </summary>
public record SessionRecord(
    string Id,
    string OwnerBot,
    long OwnerChatId,
    int OwnerStatusMessageId,
    string OwnerDisplayName,
    ScanParams Params,
    DateTimeOffset Opened,
    DateTimeOffset ExpiresAt,
    int ScanCount = 0,
    bool InFlightScan = false,
    Dictionary<string, string>? Metadata = null
);

/// <summary>
/// Returned with HTTP 409 from <c>POST /sessions</c> when one is already open.
/// Bot uses <c>Current</c> to render the "take over?" confirmation.
/// </summary>
public record SessionConflict(
    SessionRecord Current,
    string Message
);

// ── SSE event shape ─────────────────────────────────────────────────────────
//
// One record type for all events keeps JSON deserialization trivial. Fields
// that don't apply to a given event kind stay null.

public enum SessionEventType
{
    ScannerOnline,
    ScannerOffline,
    ScannerButton,
    SessionOpened,
    SessionScanning,
    SessionScanQueued,
    SessionScanProgress,
    SessionImageReady,
    SessionScanFailed,
    SessionExtended,
    SessionTerminated
}

public enum SessionTerminationReason
{
    Timeout,
    Takeover,
    Closed
}

public record SessionEvent(
    SessionEventType Type,
    // session.* events carry the current session record so a freshly connected
    // consumer can reconstruct state without separate GETs.
    SessionRecord? Session = null,
    string? SessionId = null,
    // session.scanning / session.image-ready / session.scan-failed
    int? Seq = null,
    // session.image-ready: size of the captured TIFF blob the bot is
    // about to fetch from /sessions/{id}/image/{seq}. Informational
    // only — the bot owns format selection, re-encoding, and any
    // thumbnailing once it has the raw bytes.
    long? BytesLength = null,
    string? Error = null,
    // session.scan-progress (0..100). Fired periodically during an in-flight
    // scan so consumers can draw a progress bar instead of staring at a
    // stale "scanning…" state message.
    int? PercentDone = null,
    // session.scan-queued / session.scanning: number of scans queued
    // BEHIND the current one (i.e. additional scans the user already
    // asked for that will run after this one finishes). Drives the
    // "+N queued" badge on the Scan button.
    int? QueuedCount = null,
    // session.extended
    DateTimeOffset? ExpiresAt = null,
    // session.terminated
    SessionTerminationReason? Reason = null,
    string? NewOwner = null
);
