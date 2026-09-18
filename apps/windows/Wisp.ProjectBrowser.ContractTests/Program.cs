using System.Text.Json;
using Wisp.ProjectBrowser.Contracts;

if (args.Length != 1)
    throw new ArgumentException("Pass contracts/project-browser/v1/projects.json");

var response = JsonSerializer.Deserialize<ProjectBrowserResponse>(File.ReadAllText(args[0]))
    ?? throw new InvalidOperationException("Missing response");
if (response.Schema != ProjectBrowserProtocol.Schema || response.Id != "projects-1"
    || response.Type != "projects" || response.ActivitySource != ProjectBrowserProtocol.PersistedOnly)
    throw new InvalidOperationException("Protocol envelope drift");
var project = response.Projects?.Single() ?? throw new InvalidOperationException("Missing project");
if (project.Id != "research-1" || project.Name != "RNA-seq 研究"
    || project.WorkspaceDirectory != "/Users/researcher/Projects/RNA seq"
    || project.SessionCount != 3 || project.ArtifactCount != 2
    || project.NeedsYouCount != 1 || !project.Starred || !project.SyncConfigured
    || project.LastSyncedAt != 1789500000)
    throw new InvalidOperationException("Project DTO drift");
Console.WriteLine("Shared Rust / Swift / C# project-browser fixture passed.");

var fixtureDirectory = Path.GetDirectoryName(args[0])!;
var sessions = JsonSerializer.Deserialize<ProjectBrowserResponse>(File.ReadAllText(Path.Combine(fixtureDirectory, "sessions.json")))!;
if (sessions.Type != "sessions" || sessions.Sessions?.Single().ProjectId != "research-1"
    || sessions.Sessions.Single().Status != "needs_you")
    throw new InvalidOperationException("Session DTO drift");
var transcript = JsonSerializer.Deserialize<ProjectBrowserResponse>(File.ReadAllText(Path.Combine(fixtureDirectory, "transcript.json")))!;
if (transcript.Type != "transcript" || transcript.Messages?.Count != 2
    || transcript.Messages[0].Sequence != 6 || transcript.NextBeforeSeq != 6)
    throw new InvalidOperationException("Transcript DTO drift");

var star = JsonSerializer.Deserialize<SetProjectStarredRequest>(File.ReadAllText(Path.Combine(fixtureDirectory, "set-project-starred.json")))!;
if (star.Schema != ProjectBrowserProtocol.Schema || star.Id != "projects-1"
    || star.Type != "set_project_starred" || star.ProjectId != "research-1" || !star.Starred)
    throw new InvalidOperationException("Project star command drift");
var encodedStar = JsonSerializer.SerializeToElement(star);
if (!encodedStar.GetProperty("starred").GetBoolean() || encodedStar.GetProperty("project_id").GetString() != "research-1")
    throw new InvalidOperationException("Project star serialization drift");

await NativeSettingsContractTests.Run(Path.GetFullPath(Path.Combine(fixtureDirectory, "../../native-settings/v1")));
await NativeConversationContractTests.Run(args[0]);

NativePanelTabsTests.Run();
