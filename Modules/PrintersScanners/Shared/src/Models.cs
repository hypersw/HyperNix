namespace PrintScan.Shared;

// ── Print (unchanged shape) ─────────────────────────────────────────────────

public record PrintRequest(
    string FileName,
    byte[] FileData,
    string? PageRange = null,
    int Copies = 1
);

public record PrinterStatus(
    bool Online,
    string? StatusText = null
);

// ── Scan params ─────────────────────────────────────────────────────────────

/// <summary>
/// Output format bitmask — multiple can be selected for the same scan,
/// and the daemon emits one encoded variant per set bit (same decoded
/// pixel buffer, N encodes). TIFF dropped (larger than PNG, no Telegram
/// inline preview). WebP split into lossless and lossy — the lossy
/// encoder at default settings is typically ~30% smaller than JPG
/// at visually equivalent quality on documents.
/// </summary>
[Flags]
public enum ScanFormat
{
    None = 0,
    Jpeg = 1 << 0,
    Png = 1 << 1,
    WebpLossless = 1 << 2,
    WebpLossy = 1 << 3,
}

/// <summary>
/// Parameters for one scan. Format is a bitmask — see ScanFormat.
/// JpegQuality kept for wire-compat / future use; the daemon currently
/// bakes in Q=85 regardless. Users who want knobs pick a lossless format.
/// </summary>
public record ScanParams(
    int Dpi = 200,
    ScanFormat Format = ScanFormat.Jpeg,
    int JpegQuality = 85
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
/// Request body for <c>POST /sessions</c>. Bots send this to open a scan session.
/// </summary>
public record OpenSessionRequest(
    string OwnerBot,            // "telegram", "whatsapp", "web", …
    long OwnerChatId,            // bot-specific; for TG this is the chat id
    int OwnerStatusMessageId,    // bot-side id of the status message to edit
    string OwnerDisplayName,     // free-form, for takeover notifications
    ScanParams Params
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
    bool InFlightScan = false
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
    // session.image-ready: which variant within this scan this event
    // refers to (0-based), and how many total variants to expect. Fires
    // once per variant. Consumers deliver each file as it arrives.
    int? Variant = null,
    int? VariantCount = null,
    string? ContentType = null,
    string? FileName = null,
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
