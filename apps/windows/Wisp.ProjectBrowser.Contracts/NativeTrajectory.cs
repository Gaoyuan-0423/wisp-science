using System.Text.Json;
using System.Text.Json.Nodes;
namespace Wisp.ProjectBrowser.Contracts;

// The existing wisp-dto TrajectorySnapshotDto contract, also used by WebView.
public sealed record NativeTrajectory(string FrameId, string? Model, NativeTrajectoryTurn[] Turns, NativeTrajectoryStats Stats)
{
    public static NativeTrajectory Decode(JsonNode? node, string sessionId)
    {
        var result = node?.Deserialize<NativeTrajectory>(ConversationSnapshot.JsonOptions)
            ?? throw new InvalidDataException("Missing trajectory");
        if (result.FrameId != sessionId || result.Turns is null || result.Stats is null)
            throw new InvalidDataException("Trajectory identity mismatch");
        return result;
    }
}
public sealed record NativeTrajectoryTurn(long Index, long? StartedAt, NativeTrajectoryCell[] Cells);
public sealed record NativeTrajectoryCell(string Kind, string Summary, string? DetailInput, string? DetailOutput,
    bool? Ok, bool IsError, long? Ts, long? DurationMs, NativeTrajectoryUsage? Usage);
public sealed record NativeTrajectoryUsage(long Round, string? Model, long InputTokens, long OutputTokens,
    long ReasoningTokens, long CachedInputTokens);
public sealed record NativeTrajectoryStats(long Turns, long Steps, long LlmMs, long ToolMs, long InputTokens,
    long OutputTokens, long CachedInputTokens, double? CacheHitPct, double? TokensPerSec);
