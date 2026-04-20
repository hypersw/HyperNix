using System.Text.Json;
using System.Threading.Channels;
using PrintScan.Shared;

namespace PrintScan.Daemon;

/// <summary>
/// Fan-out bus for <see cref="SessionEvent"/>s. Subscribers get a
/// bounded channel each; if a consumer is slow, oldest events are dropped
/// rather than backpressuring the publisher. Each HTTP SSE handler subscribes
/// on connect and unsubscribes on disconnect.
/// </summary>
public sealed class EventBroker
{
    private readonly List<Channel<SessionEvent>> _subscribers = [];
    private readonly Lock _lock = new();
    private readonly ILogger<EventBroker> _logger;

    public EventBroker(ILogger<EventBroker> logger) { _logger = logger; }

    /// <summary>
    /// Publish an event to all currently subscribed consumers.
    /// </summary>
    public void Publish(SessionEvent ev)
    {
        List<Channel<SessionEvent>> snapshot;
        lock (_lock) { snapshot = [.. _subscribers]; }
        foreach (var ch in snapshot)
        {
            if (!ch.Writer.TryWrite(ev))
            {
                // Channel is full — drop the oldest event and retry. Bounded
                // memory in exchange for late-joiners maybe missing older
                // events; on reconnect the current session state is sent as
                // session.opened anyway.
                _ = ch.Reader.TryRead(out _);
                _ = ch.Writer.TryWrite(ev);
            }
        }
        _logger.LogDebug("event {Type} published to {N} subscribers",
            ev.Type, snapshot.Count);
    }

    /// <summary>
    /// Subscribe. The returned reader yields events until the caller's
    /// cancellation token fires. Always use <c>await foreach</c> inside a
    /// try/finally that calls <see cref="Unsubscribe"/>.
    /// </summary>
    public ChannelReader<SessionEvent> Subscribe(out Channel<SessionEvent> token)
    {
        token = Channel.CreateBounded<SessionEvent>(new BoundedChannelOptions(64)
        {
            FullMode = BoundedChannelFullMode.DropOldest
        });
        lock (_lock) { _subscribers.Add(token); }
        return token.Reader;
    }

    public void Unsubscribe(Channel<SessionEvent> token)
    {
        lock (_lock) { _subscribers.Remove(token); }
        token.Writer.TryComplete();
    }

    /// <summary>
    /// Encode an event as a single SSE message frame. Terminated with a blank
    /// line so clients treat each as a separate message.
    /// </summary>
    public static string FormatSse(SessionEvent ev)
    {
        var json = JsonSerializer.Serialize(ev, SseJson);
        return $"data: {json}\n\n";
    }

    private static readonly JsonSerializerOptions SseJson = new()
    {
        Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() },
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };
}
