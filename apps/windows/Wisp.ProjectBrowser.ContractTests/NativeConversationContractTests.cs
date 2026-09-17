using System.Text.Json.Nodes;
using Wisp.ProjectBrowser.Contracts;

static class NativeConversationContractTests
{
    public static async Task Run(string projectFixture)
    {
        var directory = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(projectFixture)!, "../../native-conversations/v1"));
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
