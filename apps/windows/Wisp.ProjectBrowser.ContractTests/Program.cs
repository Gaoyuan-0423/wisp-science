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
