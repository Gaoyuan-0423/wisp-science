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
    bool? Ok, bool IsError, long? Ts, long? DurationMs, NativeTrajectoryUsage? Usage)
{
    public string Status(bool running) => IsError || Ok == false ? "error" : Kind == "tool" && Ok is null ? (running ? "running" : "pending") : running && Kind == "assistant" && Ok is null && DurationMs is null ? "running" : "completed";
    [System.Text.Json.Serialization.JsonIgnore]
    public string RawJson => JsonSerializer.Serialize(this, new JsonSerializerOptions(ConversationSnapshot.JsonOptions) { WriteIndented = true });
    [System.Text.Json.Serialization.JsonIgnore]
    public string Preview => Kind == "usage" && Usage is { } usage ? $"第 {usage.Round} 轮 · 输入 {usage.InputTokens} · 输出 {usage.OutputTokens} · 缓存 {usage.CachedInputTokens}" : !string.IsNullOrWhiteSpace(DetailOutput) ? DetailOutput : DetailInput ?? Summary;
    [System.Text.Json.Serialization.JsonIgnore]
    public string Source => Kind == "tool" ? DetailInput ?? Summary : Kind == "usage" && Usage is not null ? JsonSerializer.Serialize(Usage, new JsonSerializerOptions(ConversationSnapshot.JsonOptions) { WriteIndented = true }) : !string.IsNullOrWhiteSpace(DetailOutput) ? DetailOutput : Summary;
}
public sealed record NativeTrajectoryUsage(long Round, string? Model, long InputTokens, long OutputTokens,
    long ReasoningTokens, long CachedInputTokens);
public sealed record NativeTrajectoryStats(long Turns, long Steps, long LlmMs, long ToolMs, long InputTokens,
    long OutputTokens, long CachedInputTokens, double? CacheHitPct, double? TokensPerSec);

public enum NativeTrajectoryAxis { Duration, Turns, Calls }
public sealed record NativeTrajectoryRow(string Key, long Turn, NativeTrajectoryCell Cell)
{
    public static NativeTrajectoryRow[] Collect(IEnumerable<NativeTrajectoryTurn> turns, string query = "")
    {
        query = query.Trim();
        return turns.SelectMany(turn => turn.Cells.Select((cell, index) => new NativeTrajectoryRow($"{turn.Index}:{index}", turn.Index, cell)))
            .Where(row => new[] { row.Cell.Summary, row.Cell.DetailInput ?? "", row.Cell.DetailOutput ?? "" }
                .Any(text => text.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
    }
}
public sealed record NativeTrajectorySegment(string Key, string Lane, double LeftPct, double WidthPct)
{
    // Same display weighting as WebView. Missing durations are not wall-clock estimates.
    public static NativeTrajectorySegment[] Collect(IEnumerable<NativeTrajectoryRow> rows, NativeTrajectoryAxis axis)
    {
        var events = rows.Where(row => row.Cell.Kind != "usage").ToArray();
        NativeTrajectorySegment Segment(NativeTrajectoryRow row, double left, double width) =>
            new(row.Key, row.Cell.Kind == "user" ? "input" : row.Cell.Kind == "tool" ? "tools" : "model", left, width);
        if (events.Length == 0) return [];
        if (axis == NativeTrajectoryAxis.Turns)
        {
            var groups = new List<List<NativeTrajectoryRow>>();
            foreach (var row in events)
            {
                if (groups.Count > 0 && groups[^1][^1].Turn == row.Turn) groups[^1].Add(row);
                else groups.Add([row]);
            }
            var column = 100.0 / groups.Count;
            return groups.SelectMany((group, i) => group.Select((row, j) => Segment(row, i * column + j * column / group.Count, column / group.Count))).ToArray();
        }
        var weights = events.Select(row => (double)Math.Max(0, row.Cell.DurationMs ?? 0)).ToArray();
        var positive = weights.Where(value => value > 0).ToArray();
        if (axis == NativeTrajectoryAxis.Calls || positive.Length == 0) weights = events.Select(_ => 1.0).ToArray();
        else { var floor = Math.Max(1, positive.Average() * 0.5); weights = weights.Select(value => value > 0 ? value : floor).ToArray(); }
        var total = Math.Max(1, weights.Sum()); var accumulated = 0.0;
        return events.Select((row, index) => { var left = accumulated / total * 100; accumulated += weights[index]; return Segment(row, left, weights[index] / total * 100); }).ToArray();
    }
}
public sealed record NativeTrajectoryTiming(double Input, double Model, double Tools)
{
    public static NativeTrajectoryTiming? Collect(IEnumerable<NativeTrajectoryCell> source)
    {
        var cells = source.ToArray(); var timed = cells.Where(cell => cell.Ts.HasValue).ToArray();
        if (timed.Length == 0) return null;
        var span = timed.Max(cell => (double)cell.Ts!.Value + (cell.DurationMs ?? 0)) - timed.Min(cell => (double)cell.Ts!.Value);
        if (span <= 0) return null;
        var model = cells.Where(cell => cell.Kind == "assistant").Sum(cell => (double)(cell.DurationMs ?? 0));
        var tools = cells.Where(cell => cell.Kind == "tool").Sum(cell => (double)(cell.DurationMs ?? 0));
        return new(Math.Max(0, span - model - tools), Math.Max(0, model), Math.Max(0, tools));
    }
}
