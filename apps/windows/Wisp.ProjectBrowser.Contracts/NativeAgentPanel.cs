using System.Text.Json;
using System.Text.Json.Nodes;
namespace Wisp.ProjectBrowser.Contracts;
public sealed record NativeAgentWorkflow(string Id, string? FrameId, string RootWorkflowId, string? ParentAttemptId, int Depth, string Name, string Goal, string Mode, string Status, int MaxParallel, bool RequiresConfirmation, long Version, long UpdatedAt);
public sealed record NativeAgentTask(string Id, string StoredStepId, string Instruction, string[] DependsOn, JsonNode Executor, JsonNode Budget, string[] Tools, string[] ApprovalReasons, JsonNode? Result);
public sealed record NativeAgentPlan(int SchemaVersion, string ApprovalPolicy, JsonNode EditableProposal, NativeAgentTask[] Tasks, JsonNode[] ApprovalReasons);
public sealed record NativeAgentSnapshot(NativeAgentWorkflow Workflow, bool DelegationEnabled, string ApprovalPolicy, NativeAgentPlan Dynamic);
public sealed record NativeAgentResult(string WorkflowId, string StepId, long Attempt, string Status, JsonNode Response);
public enum NativeAgentAction { Approve, Run, Cancel, Discard, Retry }
public sealed record NativeAgentBudgetOverride(uint? MaxTokens = null, uint? MaxToolCalls = null, ulong? MaxCostMicrounits = null);
public interface INativeAgentPanelClient
{
    Task ActAsync(string project, string session, string workflowId, NativeAgentAction action, long? expectedVersion = null, IReadOnlyDictionary<string, NativeAgentBudgetOverride>? budgets = null, CancellationToken token = default);
    Task<NativeAgentSnapshot[]> ListAsync(string project, string session, CancellationToken token = default);
    Task<NativeAgentResult> ResultAsync(string project, string session, string workflowId, string stepId, CancellationToken token = default);
}
public sealed class NativeAgentPanelClient(INativeSettingsClient transport) : INativeAgentPanelClient
{
    public async Task ActAsync(string project, string session, string workflowId, NativeAgentAction action, long? expectedVersion = null, IReadOnlyDictionary<string, NativeAgentBudgetOverride>? budgets = null, CancellationToken token = default)
    {
        if (action == NativeAgentAction.Approve && expectedVersion is null) throw new ArgumentException("Approval requires the reviewed version", nameof(expectedVersion));
        var args = new JsonObject { ["session_id"] = session, ["workflow_id"] = workflowId, ["action"] = action.ToString().ToLowerInvariant() };
        if (expectedVersion is not null) args["expected_version"] = expectedVersion;
        if (budgets is not null) args["budget_overrides"] = JsonSerializer.SerializeToNode(budgets, ConversationSnapshot.JsonOptions);
        _ = await transport.InvokeAsync("native_conversation_panel_agent_action", args, project, token).ConfigureAwait(false);
    }
    public async Task<NativeAgentSnapshot[]> ListAsync(string project, string session, CancellationToken token = default) =>
        (await transport.InvokeAsync("native_conversation_panel_agents", new() { ["session_id"] = session }, project, token).ConfigureAwait(false))?.Deserialize<NativeAgentSnapshot[]>(ConversationSnapshot.JsonOptions)
            ?? throw new InvalidDataException("Missing agent list");
    public async Task<NativeAgentResult> ResultAsync(string project, string session, string workflowId, string stepId, CancellationToken token = default)
    {
        var result = (await transport.InvokeAsync("native_conversation_panel_agent_result", new() { ["session_id"] = session, ["workflow_id"] = workflowId, ["step_id"] = stepId }, project, token).ConfigureAwait(false))?.Deserialize<NativeAgentResult>(ConversationSnapshot.JsonOptions)
            ?? throw new InvalidDataException("Missing agent result");
        if (result.WorkflowId != workflowId || result.StepId != stepId) throw new InvalidDataException("Agent result identity mismatch");
        return result;
    }
}
