namespace PrintScan.Shared;

public record PrintRequest(
    string FileName,
    byte[] FileData,
    string? PageRange = null,
    int Copies = 1
);

public record ScanRequest(
    int Dpi = 200,
    ScanFormat Format = ScanFormat.Jpeg,
    int JpegQuality = 90
);

public enum ScanFormat { Jpeg, Png, Tiff }

public record ScanJob(
    string Id,
    ScanJobStatus Status,
    string? ResultPath = null,
    string? Error = null
);

public enum ScanJobStatus { Pending, Scanning, Done, Failed }

public record PrinterStatus(
    bool Online,
    string? StatusText = null
);

public record ScannerStatus(
    bool Online,
    string? StatusText = null,
    bool ButtonPressed = false
);

public record DeviceStatus(
    PrinterStatus Printer,
    ScannerStatus Scanner
);

public record ButtonEvent(
    int ButtonId,
    DateTime Timestamp
);
