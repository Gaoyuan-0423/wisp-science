namespace Wisp.ProjectBrowser.Contracts;

/// A view over the displayed transcript, not a separate backend store.
/// Reset disclosure state when switching transcript pages; preserve it during live updates.
public sealed record NativeProvenanceRow(int Index, string Name, string Input, string Output, bool? Ok)
{
    public string Id => $"{Index}:{Name}";
    public bool InitiallyExpanded => Ok != true;
    public bool Matches(string query) => query.Length == 0 || new[] { Name, Input, Output }.Any(value => value.Contains(query, StringComparison.CurrentCultureIgnoreCase));
    public static NativeProvenanceRow[] Collect(IEnumerable<ConversationItem> items) => items
        .Select((item, index) => (item, index)).Where(pair => pair.item.Role == "tool")
        .Select(pair => new NativeProvenanceRow(pair.index, pair.item.ToolName ?? "", pair.item.Input ?? "", pair.item.Text, pair.item.Ok)).ToArray();
}
