using System.Text.Json;
using System.Text.Json.Nodes;
namespace Wisp.ProjectBrowser.Contracts;
public sealed record NativePanelArtifact(string Id, string Name, string Kind, string Path, string? Location, long Ts, string? LogicalPath);
public sealed record NativePanelFile(string Name, bool IsDir, ulong Size, ulong? ModifiedUnixMillis);
public sealed record NativePanelFileContent(string Path, string Mime, string? Text, string? Base64, bool Truncated, ulong? TotalBytes);
public interface INativePanelClient
{
    Task<NativePanelArtifact[]> ArtifactsAsync(string project, string session, CancellationToken token = default);
    Task<NativePanelFile[]> FilesAsync(string project, string session, string path = ".", CancellationToken token = default);
    Task<NativePanelFileContent> ReadFileAsync(string project, string session, string path, CancellationToken token = default);
    Task<NativePanelFileContent> ReadArtifactAsync(string project, string session, string artifactId, CancellationToken token = default);
}
public sealed class NativePanelClient(INativeSettingsClient transport) : INativePanelClient
{
    private async Task<T> Call<T>(string action, string project, string session, JsonObject args, CancellationToken token) where T : class
    {
        args["session_id"] = session;
        return (await transport.InvokeAsync("native_conversation_panel_" + action, args, project, token).ConfigureAwait(false))?.Deserialize<T>(ConversationSnapshot.JsonOptions)
            ?? throw new InvalidDataException("Missing panel response");
    }
    public Task<NativePanelArtifact[]> ArtifactsAsync(string project, string session, CancellationToken token = default) => Call<NativePanelArtifact[]>("artifacts", project, session, new(), token);
    public Task<NativePanelFile[]> FilesAsync(string project, string session, string path = ".", CancellationToken token = default) => Call<NativePanelFile[]>("files", project, session, new() { ["path"] = path }, token);
    public Task<NativePanelFileContent> ReadFileAsync(string project, string session, string path, CancellationToken token = default) => Call<NativePanelFileContent>("readfile", project, session, new() { ["path"] = path }, token);
    public Task<NativePanelFileContent> ReadArtifactAsync(string project, string session, string artifactId, CancellationToken token = default) => Call<NativePanelFileContent>("readartifact", project, session, new() { ["artifact_id"] = artifactId }, token);
}
