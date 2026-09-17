using System.Text.Json.Serialization;

namespace Wisp.ProjectBrowser.Contracts;

/// <summary>
/// Seam for the future WinUI 3 view model. Implement using the bundled
/// wisp-service.exe and the versioned JSONL protocol; never open SQLite in UI code.
/// </summary>
public interface IProjectBrowserClient
{
    Task<ProjectListSnapshot> ListProjectsAsync(
        string databasePath,
        CancellationToken cancellationToken = default);
}

public static class ProjectBrowserProtocol
{
    public const string Schema = "wisp.project-browser.v1";
    public const string PersistedOnly = "persisted_only";
}

public sealed record ProjectListSnapshot(
    IReadOnlyList<ProjectSummary> Projects,
    string ActivitySource);

public sealed record ProjectSummary(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("description")] string Description,
    [property: JsonPropertyName("workspace_dir")] string WorkspaceDirectory,
    [property: JsonPropertyName("starred")] bool Starred,
    [property: JsonPropertyName("session_count")] long SessionCount,
    [property: JsonPropertyName("artifact_count")] long ArtifactCount,
    [property: JsonPropertyName("updated_at")] long UpdatedAt,
    [property: JsonPropertyName("running_count")] long RunningCount,
    [property: JsonPropertyName("needs_you_count")] long NeedsYouCount,
    [property: JsonPropertyName("sync_configured")] bool SyncConfigured,
    [property: JsonPropertyName("last_synced_at")] long? LastSyncedAt);

/// <summary>Decode this envelope, validate Schema/Id/Type, then expose a snapshot.</summary>
public sealed record ProjectBrowserResponse(
    [property: JsonPropertyName("schema")] string Schema,
    [property: JsonPropertyName("id")] string? Id,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("projects")] IReadOnlyList<ProjectSummary>? Projects,
    [property: JsonPropertyName("activity_source")] string? ActivitySource,
    [property: JsonPropertyName("code")] string? Code,
    [property: JsonPropertyName("message")] string? Message);
