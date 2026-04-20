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

public enum ScanFormat { Jpeg, Png, Tiff }

/// <summary>
/// Parameters for one scan. Applies to every scan within a session.
/// </summary>
public record ScanParams(
    int Dpi = 200,
    ScanFormat Format = ScanFormat.Jpeg,
    int JpegQuality = 90
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
    string? ContentType = null,
    string? FileName = null,
    long? BytesLength = null,
    string? Error = null,
    // session.extended
    DateTimeOffset? ExpiresAt = null,
    // session.terminated
    SessionTerminationReason? Reason = null,
    string? NewOwner = null
);
