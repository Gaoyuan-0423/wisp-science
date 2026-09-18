using System.Text.Json;
using System.Text.Json.Nodes;
namespace Wisp.ProjectBrowser.Contracts;

public sealed record NativeArchiveScript(string Filename, string Content);
public sealed record NativeArchiveFile(string Path, string Checksum, ulong SizeBytes, string Action,
    bool CanDelete, string Reason, string? SnapshotPath, string CleanupStatus);
public sealed record NativeArchiveFileChoice(string Path, string Action);
public sealed record NativeArchiveConfirmation(string Id, string Title, string Report, NativeArchiveScript[] Scripts, NativeArchiveFileChoice[] Files);
public sealed record NativeResearchArchive(string Id, string ProjectId, string FrameId, string SourceHash,
    string Title, string Report, NativeArchiveScript[] Scripts, NativeArchiveFile[] Files,
    long CreatedAt, long? FrozenAt, string[] Warnings)
{
    public static NativeResearchArchive? Decode(JsonNode? node, string projectId, string sessionId)
    {
        if (node is null) return null;
        var result = node.Deserialize<NativeResearchArchive>(ConversationSnapshot.JsonOptions)
            ?? throw new InvalidDataException("Missing research archive");
        if (result.ProjectId != projectId || result.FrameId != sessionId || string.IsNullOrEmpty(result.Id)
            || result.Scripts is null || result.Files is null || result.Warnings is null)
            throw new InvalidDataException("Archive identity mismatch");
        return result;
    }
    public NativeArchiveConfirmation Confirmation() => new(Id, Title, Report, Scripts, Files.Select(f => new NativeArchiveFileChoice(f.Path, f.Action)).ToArray());
}
/// <summary>Do not replay archive mutations after an ambiguous failure. Re-read
/// the saved record; a failed cleanup can follow a successful immutable freeze.</summary>
public interface INativeArchiveClient
{
    Task<NativeResearchArchive?> GetAsync(string projectId, string sessionId, CancellationToken cancellationToken = default);
    Task<NativeResearchArchive?> PrepareAsync(string projectId, string sessionId, CancellationToken cancellationToken = default);
    Task<NativeResearchArchive?> ConfirmAsync(string projectId, string sessionId, NativeArchiveConfirmation input, CancellationToken cancellationToken = default);
    Task<NativeResearchArchive?> RetryCleanupAsync(string projectId, string sessionId, CancellationToken cancellationToken = default);
    Task<string> ContinueAsync(string projectId, string sessionId, CancellationToken cancellationToken = default);
}
public sealed class NativeArchiveClient(INativeSettingsClient transport) : INativeArchiveClient
{
    private async Task<NativeResearchArchive?> Call(string action, string project, string session, NativeArchiveConfirmation? input, CancellationToken token)
    {
        JsonObject args = new() { ["session_id"] = session };
        if (input is not null) args["input"] = JsonSerializer.SerializeToNode(input, ConversationSnapshot.JsonOptions);
        return NativeResearchArchive.Decode(await transport.InvokeAsync("native_conversation_archive_" + action, args, project, token).ConfigureAwait(false), project, session);
    }
    public Task<NativeResearchArchive?> GetAsync(string projectId, string sessionId, CancellationToken cancellationToken = default) => Call("get", projectId, sessionId, null, cancellationToken);
    public Task<NativeResearchArchive?> PrepareAsync(string projectId, string sessionId, CancellationToken cancellationToken = default) => Call("prepare", projectId, sessionId, null, cancellationToken);
    public Task<NativeResearchArchive?> ConfirmAsync(string projectId, string sessionId, NativeArchiveConfirmation input, CancellationToken cancellationToken = default) => Call("confirm", projectId, sessionId, input, cancellationToken);
    public Task<NativeResearchArchive?> RetryCleanupAsync(string projectId, string sessionId, CancellationToken cancellationToken = default) => Call("retry", projectId, sessionId, null, cancellationToken);
    public async Task<string> ContinueAsync(string projectId, string sessionId, CancellationToken cancellationToken = default) =>
        (await transport.InvokeAsync("native_conversation_archive_continue", new() { ["session_id"] = sessionId }, projectId, cancellationToken).ConfigureAwait(false))?.GetValue<string>()
            ?? throw new InvalidDataException("Missing continuation ID");
}
