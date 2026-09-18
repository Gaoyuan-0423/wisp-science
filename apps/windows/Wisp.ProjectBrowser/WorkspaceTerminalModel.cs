using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

/// <summary>Reconnecting reads may retry. Open and Write are never replayed after an ambiguous failure.
/// Hiding the panel must not call Close.</summary>
public sealed class WorkspaceTerminalModel
{
    private readonly INativeTerminalClient client;
    private readonly string projectId;
    private readonly string sessionId;
    public NativeTerminalInfo[] Terminals { get; private set; } = [];
    public NativePanelContext[] Contexts { get; private set; } = [];
    public string? SelectedId { get; private set; }
    public string Output { get; private set; } = "";
    public bool Busy { get; private set; }
    public bool InputUncertain { get; private set; }
    public uint? ExitCode { get; private set; }
    public string? Error { get; private set; }
    private ulong? cursor;
    private int generation;
    private readonly INativePanelClient? panels;
    public WorkspaceTerminalModel(INativeTerminalClient client, string projectId, string sessionId, INativePanelClient? panels = null)
    {
        this.client = client; this.projectId = projectId; this.sessionId = sessionId; this.panels = panels;
    }

    public void Select(string? id)
    {
        generation++; cursor = null; SelectedId = id; ExitCode = null; Output = "";
    }

    public async Task ReloadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var rows = await client.ListAsync(projectId, sessionId, cancellationToken);
            if (rows.Any(row => row.ProjectId != projectId)) throw new InvalidDataException("Terminal project mismatch");
            Terminals = rows;
            if (SelectedId == null || rows.All(row => row.Id != SelectedId)) Select(rows.FirstOrDefault()?.Id);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Error = ex.Message; }
    }

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        await ReloadAsync(cancellationToken);
        if (panels is null) return;
        try { Contexts = (await panels.ContextsAsync(projectId, sessionId, cancellationToken)).Attached; }
        catch (Exception ex) when (ex is not OperationCanceledException) { Error = ex.Message; }
    }

    public async Task OpenAsync(string contextId, CancellationToken cancellationToken = default)
    {
        if (Busy) return;
        Busy = true; Error = null;
        try
        {
            var info = await client.OpenAsync(projectId, sessionId, contextId, cancellationToken);
            if (info.ProjectId != projectId) throw new InvalidDataException("Terminal project mismatch");
            await ReloadAsync(cancellationToken);
            Select(info.Id);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Error = "终端创建未确认成功，请刷新列表后检查：" + ex.Message;
            await ReloadAsync(cancellationToken);
        }
        finally { Busy = false; }
    }

    public async Task ReadAsync(CancellationToken cancellationToken = default)
    {
        if (SelectedId is not { } id) return;
        var current = generation;
        try
        {
            var chunk = await client.ReadAsync(projectId, sessionId, id, cursor, cancellationToken);
            if (current != generation) return;
            var bytes = chunk.Bytes(id, cursor);
            if (chunk.Reset) Output = "";
            Output += System.Text.Encoding.UTF8.GetString(bytes);
            cursor = chunk.End; ExitCode = chunk.ExitCode; Error = null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            if (current == generation) Error = ex.Message;
        }
    }

    public async Task WriteAsync(byte[] bytes, CancellationToken cancellationToken = default)
    {
        if (SelectedId is not { } id || ExitCode != null || InputUncertain) return;
        try { await client.WriteAsync(projectId, sessionId, id, bytes, cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            InputUncertain = true;
            Error = "输入未确认送达，不会自动重发：" + ex.Message;
        }
    }

    public void ResumeInput() { InputUncertain = false; Error = null; }

    public async Task CloseSelectedAsync(CancellationToken cancellationToken = default)
    {
        if (SelectedId is not { } id || Busy) return;
        Busy = true;
        try { await client.CloseAsync(projectId, sessionId, id, cancellationToken); await ReloadAsync(cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException) { Error = ex.Message; }
        finally { Busy = false; }
    }

    public void Detach() { generation++; cursor = null; }
}
