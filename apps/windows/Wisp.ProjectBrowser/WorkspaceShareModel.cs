using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

public sealed class WorkspaceShareModel(INativeShareClient client, string projectId, string sessionId)
{
    public NativeShareDraftRow[] Rows { get; private set; } = [];
    public string Keywords { get; set; } = "";
    public bool Loading { get; private set; }
    public string? Error { get; private set; }
    public NativeShareRow[] Selected => NativeShareDraft.Selected(Rows, Keywords);

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        if (Loading) return;
        Loading = true; Error = null;
        try { Rows = NativeShareDraft.From(await client.ReadAsync(projectId, sessionId, cancellationToken)); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Error = ex.Message; }
        finally { Loading = false; }
    }

    public void SelectAll(bool selected) =>
        Rows = Rows.Select(row => row with { Selected = selected }).ToArray();

    public void SetSelected(int id, bool selected) =>
        Rows = Rows.Select(row => row.Id == id ? row with { Selected = selected } : row).ToArray();

    public void Edit(int id, string text) =>
        Rows = Rows.Select(row => row.Id == id ? row with { Row = row.Row with { Text = text } } : row).ToArray();

    public Task<string> HtmlAsync(bool dark, CancellationToken cancellationToken = default) =>
        client.HtmlAsync(projectId, sessionId, Selected, dark, cancellationToken);
}
