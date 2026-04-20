using System.Text.Json;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Persistent, single-session store. Lives as a JSON file under systemd's
/// StateDirectory (<c>/var/lib/printscan/sessions.json</c>). Written
/// synchronously on every mutation — sessions mutate rarely (a few per scan)
/// so the write cost is trivial.
///
/// Thread-safety: all methods take the internal lock. Callers should never
/// hold external locks across these calls.
/// </summary>
public sealed class SessionStore
{
    private readonly string _path;
    private readonly Lock _lock = new();
    private SessionRecord? _current;

    public SessionStore(string stateDirectory)
    {
        Directory.CreateDirectory(stateDirectory);
        _path = Path.Combine(stateDirectory, "sessions.json");
        _current = Load();
    }

    public SessionRecord? Current
    {
        get { lock (_lock) { return _current; } }
    }

    /// <summary>
    /// Replace the stored session (or clear it by passing null). Persists
    /// synchronously to disk — returns after the write has been flushed.
    /// </summary>
    public void Set(SessionRecord? session)
    {
        lock (_lock)
        {
            _current = session;
            Persist();
        }
    }

    /// <summary>
    /// Mutate the current session under the lock. Returns the new value.
    /// Throws if there is no current session to mutate.
    /// </summary>
    public SessionRecord Mutate(Func<SessionRecord, SessionRecord> transform)
    {
        lock (_lock)
        {
            if (_current is null)
                throw new InvalidOperationException("No active session");
            _current = transform(_current);
            Persist();
            return _current;
        }
    }

    private SessionRecord? Load()
    {
        try
        {
            if (!File.Exists(_path)) return null;
            var json = File.ReadAllText(_path);
            if (string.IsNullOrWhiteSpace(json)) return null;
            return JsonSerializer.Deserialize<SessionRecord>(json, JsonOpts);
        }
        catch (Exception)
        {
            // Corrupt file: drop it, don't fail startup. A session is
            // ephemeral-enough that starting fresh is always acceptable.
            try { File.Delete(_path); } catch { }
            return null;
        }
    }

    private void Persist()
    {
        var tmp = _path + ".tmp";
        if (_current is null)
        {
            // No session — remove the file atomically
            try { File.Delete(_path); } catch (FileNotFoundException) { }
            return;
        }
        var json = JsonSerializer.Serialize(_current, JsonOpts);
        File.WriteAllText(tmp, json);
        File.Move(tmp, _path, overwrite: true);
    }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() }
    };
}
