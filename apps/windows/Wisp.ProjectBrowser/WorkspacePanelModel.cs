using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

/// <summary>Session-scoped right panel. File mutations are not replayed after an uncertain response.</summary>
public sealed class WorkspacePanelModel
{
    private readonly INativePanelClient client;
    private readonly string projectId;
    private readonly string sessionId;
    public NativePanelTabs Tabs { get; }
    public NativePanelArtifact[] Artifacts { get; private set; } = [];
    public NativePanelFile[] Files { get; private set; } = [];
    public NativePanelContexts? Contexts { get; private set; }
    public NativePanelFileContent? Preview { get; private set; }
    public NativeHighlight[] Highlights { get; private set; } = [];
    public NativeNotebookStar[] NotebookStars { get; private set; } = [];
    public NativeAgentSnapshot[] Agents { get; private set; } = [];
    public string Path { get; private set; } = ".";
    public bool Loading { get; private set; }
    public bool FileActionBusy { get; private set; }
    public string? Error { get; private set; }
    public string Parent => ParentPath(Path);
    public static string Child(string directory, string name) => directory is "." or "" ? name : directory.TrimEnd('/') + "/" + name;
    public static string ParentPath(string path)
    {
        var trimmed = path.Replace('\\', '/').Trim().TrimEnd('/');
        var slash = trimmed.LastIndexOf('/');
        return slash <= 0 ? "." : trimmed[..slash];
    }
    private int generation;
    private readonly INativeHighlightClient? highlights;
    private readonly INativeNotebookClient? notebook;
    private readonly INativeAgentPanelClient? agents;

    public WorkspacePanelModel(INativePanelClient client, string projectId, string sessionId, NativePanelTabs tabs,
        INativeHighlightClient? highlights = null, INativeNotebookClient? notebook = null, INativeAgentPanelClient? agents = null)
    {
        this.client = client; this.projectId = projectId; this.sessionId = sessionId; Tabs = tabs;
        this.highlights = highlights; this.notebook = notebook; this.agents = agents;
    }

    public async Task RefreshAsync(string tab, string? directory = null, CancellationToken cancellationToken = default)
    {
        Tabs.Show(tab);
        var current = ++generation;
        Loading = true; Error = null;
        var requested = directory ?? Path;
        try
        {
            if (tab is "provenance" or "sidechat") return;
            if (tab == "artifacts") Artifacts = await client.ArtifactsAsync(projectId, sessionId, cancellationToken);
            else if (tab == "hosts") Contexts = await client.ContextsAsync(projectId, sessionId, cancellationToken);
            else if (tab == "highlights" && highlights is not null) Highlights = await highlights.ListAsync(projectId, sessionId, cancellationToken);
            else if (tab == "notebook" && notebook is not null) NotebookStars = await notebook.ListStarsAsync(projectId, sessionId, cancellationToken);
            else if (tab == "agents" && agents is not null) Agents = await agents.ListAsync(projectId, sessionId, cancellationToken);
            else if (tab == "files")
            {
                Files = await client.FilesAsync(projectId, sessionId, requested, cancellationToken);
                Path = requested;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (current == generation) Error = ex.Message; }
        finally { if (current == generation) Loading = false; }
    }

    public async Task PerformFileActionAsync(NativePanelFileAction action, string path, string? newPath = null,
        CancellationToken cancellationToken = default)
    {
        if (FileActionBusy) throw new InvalidOperationException("文件操作正在进行。");
        var epoch = generation; var directory = Path;
        FileActionBusy = true;
        try
        {
            await client.FileActionAsync(projectId, sessionId, action, path, newPath, cancellationToken);
            if (epoch == generation && Tabs.Selected == "files" && Path == directory)
                await RefreshAsync("files", directory, cancellationToken);
        }
        catch (Exception)
        {
            if (epoch == generation) throw;
        }
        finally { if (epoch == generation) FileActionBusy = false; }
    }

    public async Task ReadFileAsync(string path, CancellationToken cancellationToken = default)
    {
        var current = ++generation;
        try { Preview = await client.ReadFileAsync(projectId, sessionId, path, cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException) { if (current == generation) Error = ex.Message; }
    }

    public async Task ReadArtifactAsync(string artifactId, CancellationToken cancellationToken = default)
    {
        var current = ++generation;
        try { Preview = await client.ReadArtifactAsync(projectId, sessionId, artifactId, cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException) { if (current == generation) Error = ex.Message; }
    }

    public async Task SaveFileAsync(string originalText, string text, CancellationToken cancellationToken = default)
    {
        if (Preview is null) return;
        var current = generation; var path = Preview.Path;
        await client.SaveFileAsync(projectId, sessionId, path, originalText, text, cancellationToken);
        if (current != generation || Preview?.Path != path) return;
        Preview = Preview with { Text = text, TotalBytes = (ulong)System.Text.Encoding.UTF8.GetByteCount(text) };
    }

    public void DismissPreview() { generation++; Preview = null; }
    public void Close() { generation++; Loading = false; FileActionBusy = false; Preview = null; }
}
