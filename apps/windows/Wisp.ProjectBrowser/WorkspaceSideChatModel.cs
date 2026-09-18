using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

public sealed class WorkspaceSideChatModel(INativeSideChatClient client, string projectId, string sessionId)
{
    public sealed record Row(string Question, NativeSideChatResponse? Answer, string? Model, string? Error);
    public string Draft { get; set; } = "";
    public List<NativeSideChatQuote> Quotes { get; } = [];
    public List<Row> Rows { get; } = [];
    public NativeSideChatOption[] Options { get; private set; } = [];
    public string? AcpAgentId { get; private set; }
    public bool Busy { get; private set; }
    public bool ChangingModel { get; private set; }
    public bool ModelSelectionUncertain { get; private set; }
    public string? Error { get; private set; }
    public NativeSideChatOption? Selected =>
        AcpAgentId is { } id ? Options.FirstOrDefault(option => option.Kind == "acp" && option.Id == id)
        : Options.FirstOrDefault(option => option.Kind == "http" && option.Active) ?? Options.FirstOrDefault(option => option.Kind == "http");
    public bool CanSend => !Busy && !ChangingModel && !ModelSelectionUncertain
        && (Draft.Trim().Length > 0 || Quotes.Count > 0);
    private int optionsGeneration;

    public async Task LoadOptionsAsync(CancellationToken cancellationToken = default)
    {
        var generation = ++optionsGeneration;
        try
        {
            var rows = await client.OptionsAsync(projectId, sessionId, cancellationToken);
            if (generation != optionsGeneration) return;
            Options = rows; Error = null;
            if (ModelSelectionUncertain) { AcpAgentId = null; ModelSelectionUncertain = false; }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        { if (generation == optionsGeneration) Error = ex.Message; }
    }

    public async Task SelectAsync(NativeSideChatOption option, CancellationToken cancellationToken = default)
    {
        if (Busy || ChangingModel) return;
        if (option.Kind == "acp") { AcpAgentId = option.Id; ModelSelectionUncertain = false; Error = null; return; }
        optionsGeneration++; ChangingModel = true; ModelSelectionUncertain = true; Error = null;
        try
        {
            await client.SelectHttpModelAsync(projectId, option.Id, cancellationToken);
            AcpAgentId = null;
            await LoadOptionsAsync(cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        { ModelSelectionUncertain = true; Error = ex.Message; }
        finally { ChangingModel = false; }
    }

    public async Task SendAsync(CancellationToken cancellationToken = default)
    {
        if (!CanSend) return;
        var question = NativeSideChatQuote.Question(Draft, Quotes);
        var label = Selected?.Label;
        var agent = AcpAgentId;
        Draft = ""; Quotes.Clear(); Busy = true; Error = null;
        try
        {
            var reply = await client.AskAsync(projectId, sessionId, question, agent, cancellationToken);
            Rows.Add(new(question, reply, label, null));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        { Rows.Add(new(question, null, null, ex.Message)); }
        finally { Busy = false; }
    }
}
