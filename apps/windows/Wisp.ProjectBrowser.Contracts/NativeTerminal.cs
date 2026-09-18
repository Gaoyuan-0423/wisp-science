using System.Text.Json;
using System.Text.Json.Nodes;
namespace Wisp.ProjectBrowser.Contracts;

public sealed record NativeTerminalInfo(string Id, string ProjectId, string ContextId, string Title, string Kind, string DisplayCwd, bool Running);
public sealed record NativeTerminalOutput(string TerminalId, ulong Start, ulong End, string Base64, bool Reset, uint? ExitCode)
{
    public byte[] Bytes(string expectedId, ulong? cursor)
    {
        var bytes = Convert.FromBase64String(Base64);
        if (TerminalId != expectedId || End < Start || (ulong)bytes.Length != End - Start || (!Reset && cursor != Start))
            throw new InvalidDataException("Terminal output cursor mismatch");
        return bytes;
    }
}
/// <summary>Platform terminal controls consume raw VT bytes. Reconnect reads may
/// retry; never replay Open or Write after an ambiguous failure. Closing a tab
/// terminates its process; hiding a panel must not call Close.</summary>
public interface INativeTerminalClient
{
    Task<NativeTerminalInfo[]> ListAsync(string project, string session, CancellationToken token = default);
    Task<NativeTerminalInfo> OpenAsync(string project, string session, string context, CancellationToken token = default);
    Task<NativeTerminalOutput> ReadAsync(string project, string session, string terminal, ulong? cursor, CancellationToken token = default);
    Task WriteAsync(string project, string session, string terminal, byte[] bytes, CancellationToken token = default);
    Task ResizeAsync(string project, string session, string terminal, ushort rows, ushort cols, CancellationToken token = default);
    Task CloseAsync(string project, string session, string terminal, CancellationToken token = default);
}
public sealed class NativeTerminalClient(INativeSettingsClient transport) : INativeTerminalClient
{
    private async Task<T> Read<T>(string action, string project, string session, JsonObject args, CancellationToken token) where T : class
    {
        args["session_id"] = session;
        return (await transport.InvokeAsync("native_conversation_terminal_" + action, args, project, token).ConfigureAwait(false))?.Deserialize<T>(ConversationSnapshot.JsonOptions)
            ?? throw new InvalidDataException("Missing terminal response");
    }
    private async Task Write(string action, string project, string session, JsonObject args, CancellationToken token)
    {
        args["session_id"] = session;
        await transport.InvokeAsync("native_conversation_terminal_" + action, args, project, token).ConfigureAwait(false);
    }
    public Task<NativeTerminalInfo[]> ListAsync(string project, string session, CancellationToken token = default) => Read<NativeTerminalInfo[]>("list", project, session, new(), token);
    public Task<NativeTerminalInfo> OpenAsync(string project, string session, string context, CancellationToken token = default) => Read<NativeTerminalInfo>("open", project, session, new() { ["context_id"] = context }, token);
    public Task<NativeTerminalOutput> ReadAsync(string project, string session, string terminal, ulong? cursor, CancellationToken token = default) => Read<NativeTerminalOutput>("read", project, session, new() { ["terminal_id"] = terminal, ["cursor"] = cursor }, token);
    public Task WriteAsync(string project, string session, string terminal, byte[] bytes, CancellationToken token = default) => Write("write", project, session, new() { ["terminal_id"] = terminal, ["base64"] = Convert.ToBase64String(bytes) }, token);
    public Task ResizeAsync(string project, string session, string terminal, ushort rows, ushort cols, CancellationToken token = default) => Write("resize", project, session, new() { ["terminal_id"] = terminal, ["rows"] = rows, ["cols"] = cols }, token);
    public Task CloseAsync(string project, string session, string terminal, CancellationToken token = default) => Write("close", project, session, new() { ["terminal_id"] = terminal }, token);
}
