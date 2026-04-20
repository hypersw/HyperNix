using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace PrintScan.TelegramBot;

/// <summary>
/// Disk-backed staging area for scans the bot is about to upload to Telegram.
/// Lives under RUNTIME_DIRECTORY (/run/printscan-bot on tmpfs) so we don't
/// wear the SD, but survives bot-process restarts within a single boot.
///
/// Layout:  {runtimeDir}/{sessionId}/{seq}.{ext}
///          {runtimeDir}/{sessionId}/manifest.json
/// </summary>
public sealed class Staging
{
    private readonly string _root;
    private readonly ILogger<Staging> _logger;
    private readonly Lock _lock = new();

    public Staging(string runtimeDirectory, ILogger<Staging> logger)
    {
        _root = runtimeDirectory;
        Directory.CreateDirectory(_root);
        _logger = logger;
    }

    public async Task<string> StageAsync(
        string sessionId, int seq, string extension,
        Stream data, CancellationToken ct)
    {
        var dir = Path.Combine(_root, sessionId);
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, $"{seq}.{extension}");
        await using var file = File.Create(path);
        await data.CopyToAsync(file, ct);
        _logger.LogDebug("staged {Session}#{Seq} → {Path}", sessionId, seq, path);
        return path;
    }

    public void RecordManifest(string sessionId, int seq, StagedEntry entry)
    {
        lock (_lock)
        {
            var dir = Path.Combine(_root, sessionId);
            Directory.CreateDirectory(dir);
            var manifestPath = Path.Combine(dir, "manifest.json");
            var manifest = LoadManifest(manifestPath);
            manifest[seq.ToString()] = entry;
            File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, JsonOpts));
        }
    }

    public void Remove(string sessionId, int seq)
    {
        lock (_lock)
        {
            var dir = Path.Combine(_root, sessionId);
            var manifestPath = Path.Combine(dir, "manifest.json");
            if (File.Exists(manifestPath))
            {
                var manifest = LoadManifest(manifestPath);
                manifest.Remove(seq.ToString());
                if (manifest.Count == 0)
                    File.Delete(manifestPath);
                else
                    File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest, JsonOpts));
            }
            try
            {
                foreach (var f in Directory.EnumerateFiles(dir, $"{seq}.*"))
                    File.Delete(f);
                if (Directory.Exists(dir) && !Directory.EnumerateFileSystemEntries(dir).Any())
                    Directory.Delete(dir);
            }
            catch (DirectoryNotFoundException) { }
        }
    }

    /// <summary>
    /// Scan the staging directory on startup; yield any (sessionId, seq)
    /// still present as pending retries, paired with their manifest entry.
    /// </summary>
    public IEnumerable<(string SessionId, int Seq, StagedEntry Entry, string Path)> EnumeratePending()
    {
        if (!Directory.Exists(_root)) yield break;
        foreach (var sessionDir in Directory.EnumerateDirectories(_root))
        {
            var manifestPath = Path.Combine(sessionDir, "manifest.json");
            if (!File.Exists(manifestPath)) continue;
            Dictionary<string, StagedEntry> manifest;
            try { manifest = LoadManifest(manifestPath); }
            catch { continue; }
            var sessionId = Path.GetFileName(sessionDir);
            foreach (var kv in manifest)
            {
                if (!int.TryParse(kv.Key, out var seq)) continue;
                var pattern = $"{seq}.*";
                var file = Directory.EnumerateFiles(sessionDir, pattern).FirstOrDefault();
                if (file is null) continue;
                yield return (sessionId, seq, kv.Value, file);
            }
        }
    }

    public void WipeSession(string sessionId)
    {
        lock (_lock)
        {
            var dir = Path.Combine(_root, sessionId);
            try { Directory.Delete(dir, recursive: true); }
            catch (DirectoryNotFoundException) { }
        }
    }

    private static Dictionary<string, StagedEntry> LoadManifest(string path)
    {
        if (!File.Exists(path)) return [];
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<Dictionary<string, StagedEntry>>(json, JsonOpts)
            ?? [];
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = false
    };
}

public record StagedEntry(
    long ChatId,
    string FileName,
    string ContentType,
    string Caption
);
