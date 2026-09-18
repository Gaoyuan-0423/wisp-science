using System.Text.Json;
using System.Text.Json.Nodes;

namespace Wisp.ProjectBrowser.Contracts;

public sealed record NativeNotebookCell(int Index, string Language, string Source, string Output, bool? Ok, string Origin)
{
    public string StarKey => Language + "\0" + Source;
    public string Status => Ok == true ? "ok" : Ok == false ? "error" : Origin == "assistant" ? "source" : "running";
    public bool OutputInitiallyExpanded => Ok == false;
    public static NativeNotebookCell[] Collect(IEnumerable<ConversationItem> items)
    {
        var cells = new List<NativeNotebookCell>();
        foreach (var item in items)
        {
            if (item.Role == "assistant")
            {
                foreach (var (language, source) in Fences(item.Text))
                    if (language is not ("csv" or "tsv" or "fasta" or "fa")) cells.Add(new(0, language.Length == 0 ? "text" : language, source, "", null, "assistant"));
            }
            else if (item.Role == "tool" && item.ToolName is "python" or "r" or "shell" && !string.IsNullOrWhiteSpace(item.Input))
            {
                var source = item.Input;
                var end = source.IndexOf("] ", StringComparison.Ordinal);
                if (item.ToolName != "shell" && source.StartsWith('[') && end >= 0) source = source[(end + 2)..];
                cells.Add(new(0, item.ToolName == "shell" ? "bash" : item.ToolName, source, item.Text, item.Ok, item.ToolName == "shell" ? "shell" : "repl"));
            }
        }
        var executed = cells.Where(cell => cell.Origin != "assistant").Select(cell => cell.Source.Trim()).ToHashSet();
        return cells.Where(cell => cell.Origin != "assistant" || !executed.Contains(cell.Source.Trim())).Select((cell, index) => cell with { Index = index }).ToArray();
    }
    private static IEnumerable<(string Language, string Source)> Fences(string text)
    {
        var lines = text.Split('\n').Select(line => line.EndsWith('\r') ? line[..^1] : line).ToList();
        if (text.EndsWith('\n')) lines.RemoveAt(lines.Count - 1);
        for (var index = 0; index < lines.Count; index++)
        {
            var fence = lines[index].Trim();
            if (!fence.StartsWith("```", StringComparison.Ordinal)) continue;
            var raw = fence.TrimStart('`').Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            var language = new string(raw.Select(c => c is >= 'A' and <= 'Z' ? (char)(c + 32) : c).ToArray());
            var end = index + 1;
            while (end < lines.Count && !lines[end].Trim().StartsWith("```", StringComparison.Ordinal)) end++;
            var source = string.Join("\n", lines.Skip(index + 1).Take(end - index - 1));
            if (source.Length > 0) yield return (language, source);
            index = end;
        }
    }
}
public sealed record NativeNotebookStar(string Id, string Kind, string? Language, string Code, string SourceProjectId, string SourceSessionId)
{
    public bool Belongs(string project, string session) => Kind == "code" && SourceProjectId == project && SourceSessionId == session;
    public bool Matches(NativeNotebookCell cell) => (Language ?? "") == cell.Language && Code == cell.Source;
}
public interface INativeNotebookClient
{
    Task<NativeNotebookStar[]> ListStarsAsync(string project, string session, CancellationToken token = default);
    Task<NativeNotebookStar> StarAsync(string project, string session, string language, string code, CancellationToken token = default);
    Task<bool> UnstarAsync(string project, string session, string id, CancellationToken token = default);
}
public sealed class NativeNotebookClient(INativeSettingsClient transport) : INativeNotebookClient
{
    public async Task<NativeNotebookStar[]> ListStarsAsync(string project, string session, CancellationToken token = default)
    {
        var value = await transport.InvokeAsync("native_conversation_panel_notebook_stars", new JsonObject { ["session_id"] = session }, project, token).ConfigureAwait(false);
        var rows = value?.Deserialize<NativeNotebookStar[]>(ConversationSnapshot.JsonOptions) ?? throw new InvalidDataException("Missing notebook stars");
        if (rows.Any(row => !row.Belongs(project, session))) throw new InvalidDataException("Notebook star scope mismatch");
        return rows;
    }
    public async Task<NativeNotebookStar> StarAsync(string project, string session, string language, string code, CancellationToken token = default)
    {
        var value = await transport.InvokeAsync("native_conversation_panel_notebook_star", new JsonObject { ["session_id"] = session, ["language"] = language, ["code"] = code }, project, token).ConfigureAwait(false);
        var row = value?.Deserialize<NativeNotebookStar>(ConversationSnapshot.JsonOptions) ?? throw new InvalidDataException("Missing saved code");
        if (!row.Belongs(project, session) || row.Language != language || row.Code != code) throw new InvalidDataException("Saved code identity mismatch");
        return row;
    }
    public async Task<bool> UnstarAsync(string project, string session, string id, CancellationToken token = default) =>
        (await transport.InvokeAsync("native_conversation_panel_notebook_unstar", new JsonObject { ["session_id"] = session, ["library_item_id"] = id }, project, token).ConfigureAwait(false))?.GetValue<bool>() ?? throw new InvalidDataException("Missing removal result");
}
