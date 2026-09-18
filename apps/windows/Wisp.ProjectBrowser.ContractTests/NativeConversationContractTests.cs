using System.Text.Json;
using System.Text.Json.Nodes;
using Wisp.ProjectBrowser.Contracts;

static class NativeConversationContractTests
{
    public static async Task Run(string projectFixture)
    {
        var directory = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(projectFixture)!, "../../native-conversations/v1"));
        var panel = JsonSerializer.Deserialize<NativePanelFile[]>(File.ReadAllText(Path.Combine(directory, "panel-files.json")), ConversationSnapshot.JsonOptions)!;
        Require(panel[0].IsDir && panel[1].Name == "README.md", "Panel file fixture drift");
        var preview = JsonSerializer.Deserialize<NativePanelFileContent>(File.ReadAllText(Path.Combine(directory, "panel-preview.json")), ConversationSnapshot.JsonOptions)!;
        Require(preview.Truncated && preview.TotalBytes == 8000000, "Truncated preview drift");
        var terminal = JsonSerializer.Deserialize<NativeTerminalOutput>(File.ReadAllText(Path.Combine(directory, "terminal-output.json")), ConversationSnapshot.JsonOptions)!;
        Require(System.Text.Encoding.UTF8.GetString(terminal.Bytes("terminal-a", null)) == "hello", "Terminal byte fixture drift");
        try { terminal.Bytes("other", null); throw new Exception("Expected terminal scope rejection"); } catch (InvalidDataException) { }
        try { (terminal with { Reset = false }).Bytes("terminal-a", 5); throw new Exception("Expected terminal replay rejection"); } catch (InvalidDataException) { }
        var share = JsonSerializer.Deserialize<NativeShareRow[]>(File.ReadAllText(Path.Combine(directory, "share.json")), ConversationSnapshot.JsonOptions)!;
        Require(share.Length == 3 && share[1].Role == "reasoning", "Share fixture drift");
        var contexts = JsonSerializer.Deserialize<NativePanelContexts>(File.ReadAllText(Path.Combine(directory, "panel-contexts.json")), ConversationSnapshot.JsonOptions)!;
        Require(contexts.Attached.Select(c => c.Id).SequenceEqual(new[] { "local", "ssh:gpu" }) && contexts.Available.Single().Id == "wsl:ubuntu", "Context session scope drift");
        var activity = JsonSerializer.Deserialize<NativeContextActivity>(File.ReadAllText(Path.Combine(directory, "panel-activity.json")), ConversationSnapshot.JsonOptions)!;
        Require(activity.Runtimes[0].Key.SessionId == "session-a" && activity.Runtimes[0].ResidentMemoryBytes == 104857600 && activity.Runs[0].Status == "running", "Activity contract casing drift");
        var run = JsonSerializer.Deserialize<NativeRun>(File.ReadAllText(Path.Combine(directory, "panel-run.json")), ConversationSnapshot.JsonOptions)!;
        Require(run.StdoutTail == "Processed 10 samples", "Run detail drift");
        var objects = JsonSerializer.Deserialize<NativeRuntimeObjects>(File.ReadAllText(Path.Combine(directory, "panel-runtime-objects.json")), ConversationSnapshot.JsonOptions)!;
        Require(objects.TotalCount == 1 && objects.Objects[0].TypeName == "list", "Runtime inspection drift");
        var execution = JsonSerializer.Deserialize<NativeRuntimeExecution>(File.ReadAllText(Path.Combine(directory, "panel-runtime-execution.json")), ConversationSnapshot.JsonOptions)!;
        Require(execution.Text == "[stdout]\n42" && execution.Plots.Length == 0, "Runtime execution fixture drift");
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
        var runtimeFake = new Fake(); var runtimeClient = new NativeContextActivityClient(runtimeFake);
        await runtimeClient.StopRuntimeAsync("project-a", "session-a", "runtime-a", 2);
        Require(runtimeFake.Args?["runtime_generation"]?.GetValue<ulong>() == 2 && runtimeFake.Args?["session_id"]?.GetValue<string>() == "session-a", "Runtime stop lost generation/scope");
        runtimeFake.Fail = true;
        try { await runtimeClient.ExecuteAsync("project-a", "session-a", "local", "python", "print(42)"); } catch (IOException) { }
        Require(runtimeFake.Calls == 2 && runtimeFake.Args?["code"]?.GetValue<string>() == "print(42)", "Uncertain runtime execution replayed or code changed");
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
