using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

/// <summary>Pinned to one project/session. Late outline responses cannot reopen a closed view.</summary>
public sealed class WorkspaceOutlineModel(INativeConversationClient client, string projectId, string sessionId)
{
    public ConversationOutlineEntry[] Entries { get; private set; } = [];
    public ConversationSnapshot? History { get; private set; }
    public int? HistoryItemIndex { get; private set; }
    public bool Loading { get; private set; }
    public string? Error { get; private set; }
    public string Query { get; set; } = "";
    public IEnumerable<ConversationOutlineEntry> Visible =>
        Entries.Where(entry => Query.Length == 0 || entry.Text.Contains(Query, StringComparison.CurrentCultureIgnoreCase));
    private int generation;

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        if (Loading) return;
        var current = ++generation;
        Loading = true; Error = null;
        try
        {
            var rows = await client.OutlineAsync(projectId, sessionId, cancellationToken);
            if (current == generation) Entries = rows;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (current == generation) Error = ex.Message; }
        finally { if (current == generation) Loading = false; }
    }

    public async Task OpenQuestionAsync(ConversationOutlineEntry entry, CancellationToken cancellationToken = default)
    {
        var current = generation;
        try
        {
            var page = await client.SnapshotAsync(projectId, sessionId, entry.BeforeSeq, cancellationToken);
            if (current != generation) return;
            var index = QuestionItemIndex(entry.UserIndex, page.UserOffset, page.Items)
                ?? throw new InvalidOperationException("问题位置已变化，请刷新大纲后重试。");
            History = page; HistoryItemIndex = index; Error = null;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (current == generation) Error = ex.Message; }
    }

    public void Close() { generation++; Loading = false; History = null; HistoryItemIndex = null; }

    public static int? QuestionItemIndex(int target, int? offset, IEnumerable<ConversationItem> items)
    {
        if (offset is null) return null;
        var index = offset.Value;
        var position = 0;
        foreach (var item in items)
        {
            if (item.Role == "user")
            {
                if (index == target) return position;
                index++;
            }
            position++;
        }
        return null;
    }
}

/// <summary>Cross-project needs-you list. Reset when the hosting project changes.</summary>
public sealed class WorkspaceInboxModel(INativeConversationClient client)
{
    public NativeInboxEntry[] Entries { get; private set; } = [];
    public bool Loading { get; private set; }
    public string? Error { get; private set; }
    private int generation;
    private string? projectId;

    public async Task RefreshAsync(string projectId, CancellationToken cancellationToken = default)
    {
        if (Loading) return;
        this.projectId = projectId;
        var current = ++generation;
        Loading = true;
        try
        {
            var rows = await client.InboxAsync(projectId, cancellationToken);
            if (current == generation) { Entries = rows.Where(row => row.Status == "needs_you").ToArray(); Error = null; }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (current == generation) Error = ex.Message; }
        finally { if (current == generation) Loading = false; }
    }

    public async Task MarkOpenedAsync(NativeInboxEntry entry, CancellationToken cancellationToken = default)
    {
        var current = generation;
        try { await client.MarkSeenAsync(entry.ProjectId, entry.Id, cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            if (current == generation) Error = "未能标记已查看：" + ex.Message;
        }
        if (current == generation && projectId is { } id) { Loading = false; await RefreshAsync(id, cancellationToken); }
    }

    public void Reset() { generation++; Entries = []; Error = null; Loading = false; projectId = null; }
}

public sealed class WorkspaceTrajectoryModel(INativeConversationClient client, string projectId, string sessionId)
{
    public NativeTrajectory? Snapshot { get; private set; }
    public bool Loading { get; private set; }
    public string? Error { get; private set; }
    public string Query { get; set; } = "";
    public NativeTrajectoryAxis Axis { get; set; } = NativeTrajectoryAxis.Duration;
    public NativeTrajectoryRow[] Rows => NativeTrajectoryRow.Collect(Snapshot?.Turns ?? [], Query);
    public NativeTrajectorySegment[] Segments => NativeTrajectorySegment.Collect(Rows, Axis);
    private int generation;

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        if (Loading) return;
        var current = ++generation;
        Loading = true;
        try
        {
            var snapshot = await client.TrajectoryAsync(projectId, sessionId, cancellationToken);
            if (current == generation) { Snapshot = snapshot; Error = null; }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (current == generation) Error = ex.Message; }
        finally { if (current == generation) Loading = false; }
    }

    public async Task<string> ExportHtmlAsync(CancellationToken cancellationToken = default) =>
        await client.TrajectoryHtmlAsync(projectId, sessionId, cancellationToken);

    public void Close() { generation++; Loading = false; }
}
