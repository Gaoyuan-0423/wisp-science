using System.Text.Json;
using System.Text.Json.Nodes;
namespace Wisp.ProjectBrowser.Contracts;
public sealed record NativeShareRow(string Role, string Text);
/// <summary>Send only the user's selected, edited and redacted rows to HtmlAsync.
/// PNG rendering and file dialogs belong to the native frontend.</summary>
public interface INativeShareClient
{
    Task<NativeShareRow[]> ReadAsync(string projectId, string sessionId, CancellationToken cancellationToken = default);
    Task<string> HtmlAsync(string projectId, string sessionId, NativeShareRow[] rows, bool dark = false, CancellationToken cancellationToken = default);
}
public sealed class NativeShareClient(INativeSettingsClient transport) : INativeShareClient
{
    public async Task<NativeShareRow[]> ReadAsync(string projectId, string sessionId, CancellationToken cancellationToken = default) =>
        (await transport.InvokeAsync("native_conversation_share", new() { ["session_id"] = sessionId }, projectId, cancellationToken).ConfigureAwait(false))?.Deserialize<NativeShareRow[]>(ConversationSnapshot.JsonOptions)
            ?? throw new InvalidDataException("Missing share rows");
    public async Task<string> HtmlAsync(string projectId, string sessionId, NativeShareRow[] rows, bool dark = false, CancellationToken cancellationToken = default) =>
        (await transport.InvokeAsync("native_conversation_share_html", new() { ["session_id"] = sessionId, ["rows"] = JsonSerializer.SerializeToNode(rows, ConversationSnapshot.JsonOptions), ["dark"] = dark }, projectId, cancellationToken).ConfigureAwait(false))?.GetValue<string>()
            ?? throw new InvalidDataException("Missing share document");
}
