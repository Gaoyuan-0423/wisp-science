using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

/// <summary>Do not replay confirm/continue after an ambiguous failure. Re-read the saved record.</summary>
public sealed class WorkspaceArchiveModel(INativeArchiveClient client, string projectId, string sessionId)
{
    public NativeResearchArchive? Archive { get; private set; }
    public bool Accepted { get; set; }
    public bool Busy { get; private set; }
    public string? Error { get; private set; }
    public bool Frozen => Archive?.FrozenAt != null;
    public bool CanConfirm => Archive != null && !Frozen && Accepted && !Busy;
    public ulong DeletedBytes => Archive?.Files.Where(file => file.Action == "delete").Aggregate(0UL, (sum, file) => sum + file.SizeBytes) ?? 0;

    public void Edit(string title, string report)
    {
        if (Archive is null || Frozen || Busy) return;
        Archive = Archive with { Title = title, Report = report };
    }

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        if (Busy) return;
        Busy = true; Error = null;
        try
        {
            Archive = await client.GetAsync(projectId, sessionId, cancellationToken)
                ?? await client.PrepareAsync(projectId, sessionId, cancellationToken);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Error = ex.Message; }
        finally { Busy = false; }
    }

    public Task PrepareAsync(CancellationToken cancellationToken = default) => MutateAsync(() => client.PrepareAsync(projectId, sessionId, cancellationToken), cancellationToken);

    public Task RetryCleanupAsync(CancellationToken cancellationToken = default) =>
        Frozen ? MutateAsync(() => client.RetryCleanupAsync(projectId, sessionId, cancellationToken), cancellationToken) : Task.CompletedTask;

    public Task ConfirmAsync(CancellationToken cancellationToken = default)
    {
        if (!CanConfirm || Archive is null) return Task.CompletedTask;
        var input = Archive.Confirmation();
        return MutateAsync(() => client.ConfirmAsync(projectId, sessionId, input, cancellationToken), cancellationToken);
    }

    public async Task<string?> ContinueAsync(CancellationToken cancellationToken = default)
    {
        if (!Frozen || Busy) return null;
        Busy = true; Error = null;
        try { return await client.ContinueAsync(projectId, sessionId, cancellationToken); }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex)
        {
            Error = "继续研究未确认成功，请刷新会话列表后检查：" + ex.Message;
            return null;
        }
        finally { Busy = false; }
    }

    private async Task MutateAsync(Func<Task<NativeResearchArchive?>> action, CancellationToken cancellationToken)
    {
        if (Busy) return;
        Busy = true; Error = null; Accepted = false;
        try { Archive = await action(); }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Error = ex.Message;
            try { if (await client.GetAsync(projectId, sessionId, cancellationToken) is { } saved) Archive = saved; }
            catch { }
        }
        finally { Busy = false; }
    }
}
