using System.Text.Json;
using System.Text.Json.Nodes;
using Wisp.ProjectBrowser.Contracts;

static class NativeConversationContractTests
{
    public static async Task Run(string projectFixture)
    {
        var directory = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(projectFixture)!, "../../native-conversations/v1"));
        var share = JsonSerializer.Deserialize<NativeShareRow[]>(File.ReadAllText(Path.Combine(directory, "share.json")), ConversationSnapshot.JsonOptions)!;
        Require(share.Length == 3 && share[1].Role == "reasoning", "Share fixture drift");
        var archiveNode = JsonNode.Parse(File.ReadAllText(Path.Combine(directory, "archive.json")));
        var archive = NativeResearchArchive.Decode(archiveNode, "project-a", "session-a")!;
        Require(archive.Confirmation().Files[0].Path == "results/qc.txt" && archive.FrozenAt is null, "Archive fixture drift");
        try { NativeResearchArchive.Decode(archiveNode, "other", "session-a"); throw new Exception("Expected archive scope rejection"); } catch (InvalidDataException) { }
        var inbox = JsonSerializer.Deserialize<NativeInboxEntry[]>(File.ReadAllText(Path.Combine(directory, "inbox.json")), ConversationSnapshot.JsonOptions)!;
        Require(inbox.Length == 2 && inbox[1].ProjectId == "project-b" && inbox[1].Id == "session-b", "Inbox cross-project identity drift");
        var trajectoryNode = JsonNode.Parse(File.ReadAllText(Path.Combine(directory, "trajectory.json")));
        var trajectory = NativeTrajectory.Decode(trajectoryNode, "session-a");
        Require(trajectory.Turns[0].Cells[0].DurationMs == 40 && trajectory.Stats.OutputTokens == 20, "Trajectory fixture drift");
        try { NativeTrajectory.Decode(trajectoryNode, "other"); throw new Exception("Expected trajectory scope rejection"); } catch (InvalidDataException) { }
        var outline = JsonSerializer.Deserialize<ConversationOutlineEntry[]>(File.ReadAllText(Path.Combine(directory, "outline.json")), ConversationSnapshot.JsonOptions)!;
        Require(outline.Length == 2 && outline[0].BeforeSeq == 8 && outline[1].BeforeSeq is null && outline[1].UserIndex == 1, "Outline cursor drift");
        var node = JsonNode.Parse(File.ReadAllText(Path.Combine(directory, "snapshot.json")))!;
        var snapshot = ConversationSnapshot.Decode(node, "project-a", "session-a");
        Require(snapshot.Items.Length == 2 && snapshot.Approvals[0].ApprovalId == "approval-a", "Shared snapshot drift");
        try { ConversationSnapshot.Decode(node, "other", "session-a"); throw new Exception("Expected scope rejection"); } catch (InvalidDataException) { }
        var cursor = new ConversationCursor("project-a", "session-a");
        Require(cursor.TryAccept(snapshot), "First snapshot rejected");
        Require(!cursor.TryAccept(snapshot) && !cursor.TryAccept(snapshot with { Sequence = 1 }), "Duplicate/older snapshot replayed");
        Require(cursor.TryAccept(snapshot with { Epoch = "host-two", Sequence = 1 }), "Restart did not reset sequence");
        Require(!cursor.TryAccept(snapshot with { Sequence = 100 }), "Retired host response was applied");
        var fake = new Fake(); var client = new NativeConversationClient(fake);
        await client.ApproveAsync("project-a", "session-a", "approval-a", false);
        Require(fake.Args?["approval_id"]?.GetValue<string>() == "approval-a" && fake.Project == "project-a", "Approval lost identity");
        fake.Fail = true;
        try { await client.SendAsync("project-a", "session-a", Guid.NewGuid(), "hello"); } catch (IOException) { }
        Require(fake.Calls == 2, "Ambiguous send was replayed");
        Console.WriteLine("Native conversation fixture, ordering, restart, approval and no-replay tests passed.");
    }
    static void Require(bool value, string message) { if (!value) throw new Exception(message); }
    sealed class Fake : INativeSettingsClient
    {
        public JsonObject? Args; public string? Project; public int Calls; public bool Fail;
        public Task<JsonNode?> InvokeAsync(string command, JsonObject arguments, string? projectId = null, CancellationToken cancellationToken = default)
        {
            Calls++; Args = arguments; Project = projectId;
            if (Fail) throw new IOException("Lost response");
            return Task.FromResult<JsonNode?>(null);
        }
    }
}
