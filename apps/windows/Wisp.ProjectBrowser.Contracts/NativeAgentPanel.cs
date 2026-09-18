using System.Text.Json;
using System.Text.Json.Nodes;
namespace Wisp.ProjectBrowser.Contracts;
public sealed record NativeAgentWorkflow(string Id, string? FrameId, string RootWorkflowId, string? ParentAttemptId, int Depth, string Name, string Goal, string Mode, string Status, int MaxParallel, bool RequiresConfirmation, long Version, long UpdatedAt);
public sealed record NativeAgentTask(string Id, string StoredStepId, string Instruction, string[] DependsOn, JsonNode Executor, JsonNode Budget, string[] Tools, string[] ApprovalReasons, JsonNode? Result);
public sealed record NativeAgentPlan(int SchemaVersion, string ApprovalPolicy, JsonNode EditableProposal, NativeAgentTask[] Tasks, JsonNode[] ApprovalReasons);
public sealed record NativeAgentSnapshot(NativeAgentWorkflow Workflow, bool DelegationEnabled, string ApprovalPolicy, NativeAgentPlan Dynamic);
public sealed record NativeAgentResult(string WorkflowId, string StepId, long Attempt, string Status, JsonNode Response);
public interface INativeAgentPanelClient
{
    Task<NativeAgentSnapshot[]> ListAsync(string project, string session, CancellationToken token = default);
    Task<NativeAgentResult> ResultAsync(string project, string session, string workflowId, string stepId, CancellationToken token = default);
}
public sealed class NativeAgentPanelClient(INativeSettingsClient transport) : INativeAgentPanelClient
{
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
