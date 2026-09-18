using System.Text.Json;

using System.Text.Json.Nodes;

namespace Wisp.ProjectBrowser.Contracts;

public sealed record NativeHighlight(string Id, string Kind, string Title, string Code, string SourceProjectId, string SourceSessionId, long CreatedAt)
{
    public bool Belongs(string project, string session) => Kind == "text" && SourceProjectId == project && SourceSessionId == session;
}
public interface INativeHighlightClient
{
    Task<NativeHighlight[]> ListAsync(string project, string session, CancellationToken token = default);
    Task<bool> RemoveAsync(string project, string session, string id, CancellationToken token = default);
}
public sealed class NativeHighlightClient(INativeSettingsClient transport) : INativeHighlightClient
{
    public async Task<NativeHighlight[]> ListAsync(string project, string session, CancellationToken token = default)
    {
        var result = await transport.InvokeAsync("native_conversation_panel_highlights", new JsonObject { ["session_id"] = session }, project, token).ConfigureAwait(false);
        var rows = result?.Deserialize<NativeHighlight[]>(ConversationSnapshot.JsonOptions) ?? throw new InvalidDataException("Missing highlights");
        if (rows.Any(row => !row.Belongs(project, session))) throw new InvalidDataException("Highlight scope mismatch");
        return rows;
    }
    public async Task<bool> RemoveAsync(string project, string session, string id, CancellationToken token = default) =>
        (await transport.InvokeAsync("native_conversation_panel_highlight_remove", new JsonObject { ["session_id"] = session, ["library_item_id"] = id }, project, token).ConfigureAwait(false))?.GetValue<bool>() ?? throw new InvalidDataException("Missing removal result");
}
public static class NativeSavedExcerpt
{
    /// UTF-16 range in rendered text for WinUI highlighting; ignores whitespace like WebView.
    public static Range? Find(string text, string excerpt)
    {
        var needle = new string(excerpt.Where(c => !char.IsWhiteSpace(c)).ToArray());
        if (needle.Length == 0) return null;
        var indexed = text.Select((c, index) => (c, index)).Where(pair => !char.IsWhiteSpace(pair.c)).ToArray();
        var offset = new string(indexed.Select(pair => pair.c).ToArray()).IndexOf(needle, StringComparison.Ordinal);
        return offset < 0 ? null : new Range(indexed[offset].index, indexed[offset + needle.Length - 1].index + 1);
    }
}
