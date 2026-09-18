using System.Text.Json.Nodes;
using Wisp.ProjectBrowser;
using Wisp.ProjectBrowser.Contracts;

internal static class AppearanceSettingsTests
{
    public static async Task RunAsync()
    {
        var client = new Fake();
        var model = new AppearanceSettingsModel(client, "project-a");
        await model.LoadAsync();
        model.Draft!["theme"] = "dark";
        await model.LoadAsync();
        Check(model.Draft["theme"]!.GetValue<string>() == "dark", "refresh preserves unsaved draft");
        client.Fail = true;
        try { await model.SaveAsync(); throw new Exception("Expected failure"); } catch (IOException) { }
        Check(client.Writes == 1 && model.HasChanges && !model.Busy, "failed mutation retains draft without retry");
        client.Fail = false;
        client.Pending = new();
        var save = model.SaveAsync();
        await model.SaveAsync();
        Check(client.Writes == 2, "duplicate save blocked while busy");
        client.Pending.SetResult(client.Sent!.DeepClone());
        await save;
        Check(!model.HasChanges && client.Sent!["future_field"]!["nested"]!.GetValue<int>() == 7,
            "successful roundtrip preserves unknown fields");
        Check(client.Project == "project-a", "explicit project identity forwarded");
        model.Draft!["theme"] = "light"; model.Discard();
        Check(model.Draft["theme"]!.GetValue<string>() == "dark", "discard restores confirmed save");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try { await model.LoadAsync(cancelled.Token); throw new Exception("Expected cancellation"); } catch (OperationCanceledException) { }
        Check(!model.Busy, "cancellation releases busy state");
        var missingDatabase = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "wisp.sqlite");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            using var unexpected = await NativeSettingsClient.ConnectAsync(missingDatabase, Environment.ProcessPath, deadline.Token);
            throw new Exception("Expected exited host failure");
        }
        catch (InvalidOperationException ex) when (ex.Message.Contains("设置宿主已退出"))
        { Check(true, "incompatible exiting host fails promptly instead of waiting indefinitely"); }
    }

    private static void Check(bool passed, string message)
    {
        if (!passed) throw new Exception(message);
        Console.WriteLine("PASS appearance: " + message);
    }

    private sealed class Fake : INativeSettingsClient
    {
        public bool Fail;
        public int Writes;
        public string? Project;
        public JsonNode? Sent;
        public TaskCompletionSource<JsonNode?>? Pending;
        public Task<JsonNode?> InvokeAsync(string command, JsonObject arguments, string? projectId = null, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested(); Project = projectId;
            if (command == "get_appearance_prefs") return Task.FromResult(JsonNode.Parse("{\"theme\":\"light\",\"future_field\":{\"nested\":7}}"));
            if (command != "set_appearance_prefs") throw new Exception("Unexpected command");
            Writes++; Sent = arguments["prefs"]!.DeepClone();
            return Fail ? Task.FromException<JsonNode?>(new IOException("lost response")) : Pending?.Task ?? Task.FromResult<JsonNode?>(Sent.DeepClone());
        }
    }
}
