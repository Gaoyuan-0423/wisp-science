# Native project browser preview

Wisp now has a small SwiftUI project browser alongside the existing Tauri client.
It lists real projects, preserves the desktop's ordering and metadata, searches
names/descriptions/paths, refreshes on demand, and reveals a selected workspace
in Finder. The existing desktop remains the client for chat and execution.

## Visual alignment with the WebView

The SwiftUI landing page follows `ui/src/styles/projects.css`: a centered page
with the Wisp wordmark and tagline, warm paper surfaces, teal actions, compact
project cards, and two equal columns. Below 820 points it switches to one column;
long pages scroll. The right column contains the selected project's saved
metadata, rather than the WebView's recent-session navigation, since session
services and chat are outside this first preview.

Search matches project names, descriptions, and directories. The star button
filters saved favorites without changing them. Selection stays on the same ID
after refresh if it remains visible; search/filter changes select the first
visible project or show an empty overview. The footer provides system/light/dark
appearance choices and the successful-read time; hover over the database filename
to see its full path.

Brand SVGs, the existing `compose_icon()` glyphs, and semantic colors are exported
from the WebView sources into the Swift resource bundle. There is no second icon
set and no WebView embedded in the SwiftUI screen. After changing those shared
sources, run:

```bash
python3 scripts/sync_native_design.py
python3 scripts/sync_native_design.py --check
```

CI and the app build check for asset drift. WinUI can consume the same SVG and
palette exports when its views are implemented. Native system font rendering,
window chrome, and file selection remain platform-specific; unsupported WebView
actions (chat, project creation/import, settings) are not displayed as dead controls.

## Build and run on macOS

Requires macOS 13+, Xcode with Swift 5.9+ command-line tools, and the repository's
Rust toolchain. No Swift package dependencies are downloaded.

```bash
bash scripts/build_native_macos.sh
open "target/native-macos/Wisp Science Preview.app"
```

This builds a debug app for the current architecture, bundles `wisp-service`, and
applies an ad-hoc local signature. It is a local preview, not a notarized release
or universal installer. Its bundle ID is `science.wisp-science.native-preview`;
it has separate preferences and no updater.

The default database matches the current desktop location:
`~/Library/Application Support/science.wisp-science/wisp-science/wisp.sqlite`.
Use **Choose database / 选择数据库** (Command-O) for another existing database;
**Refresh / 刷新** (Command-R) reloads it. Database selection is remembered by the
preview. For development, `WISP_BROWSER_DATABASE` overrides the path and
`WISP_SERVICE_PATH` overrides the bundled service executable.

The service opens SQLite in read-only mode. It does not create a missing
database, run migrations, mutate projects, access model credentials, or execute
tools. Databases from before project stars are supported without migration;
their projects are treated as unstarred. Other incompatible older schemas may fail to query; open them
with the current desktop to perform the normal upgrade. SQLite may use its
ordinary WAL/SHM coordination files when a desktop writer is also active.

## Status semantics

The standalone preview has no access to the desktop's in-memory Agent and
approval state. Responses explicitly declare `activity_source: persisted_only`.
The UI shows saved session/artifact counts, saved unread replies, and sync
metadata; it labels live execution and approval status as unavailable. A zero
`running_count` in this mode must **not** be presented as proof that no work is
running. Failed refreshes retain the last successful snapshot with its timestamp
and an error banner; selecting a different database clears the old snapshot.

## Shared boundary and WinUI 3 seam

- `wisp-app::projects` owns the project-list query and activity enrichment. The
  existing Tauri command calls the same service with real runtime snapshots.
- `wisp-dto::project_browser` owns the native protocol shapes.
- `wisp-service --database <path>` exposes those queries over stdin/stdout JSONL.
- `apps/macos` contains a Foundation transport client and SwiftUI presentation.
- `apps/windows/Wisp.ProjectBrowser.Contracts` provides `IProjectBrowserClient`
  and C# response/project DTOs for a future WinUI 3 view model. It intentionally
  contains no WinUI window or transport implementation yet.
- `contracts/project-browser/v1/projects.json` is decoded by Rust, Swift, and
  the C# contract smoke test to detect wire-format drift.

The UI never queries SQLite directly. The macOS adapter starts one short-lived
service per refresh and closes stdin after one request. The service also accepts
multiple requests per process, enabling a future persistent Windows adapter.

Each UTF-8 request is one JSON line, at most 64 KiB including its newline:

```json
{"schema":"wisp.project-browser.v1","id":"projects-1","type":"list_projects"}
{"schema":"wisp.project-browser.v1","id":"capabilities-1","type":"capabilities"}
```

Every response repeats `schema` and `id`. A `projects` response contains
`projects: ProjectSummary[]` and `activity_source: persisted_only`. A
`capabilities` response contains `commands` and `read_only: true`. An `error`
response contains `code` (`invalid_request`, `unsupported_schema`, or
`query_failed`) and `message`. Malformed requests have `id: null`. Stdout carries
protocol responses only; startup/transport failures go to stderr and exit
nonzero. EOF exits the process. Clients validate schema, correlation ID, response
type, and supported activity source before presenting results. The macOS client
terminates a service that exceeds its 30-second query deadline.

## Verification

```bash
cargo test -p wisp-app -p wisp-service
swift test --package-path apps/macos --scratch-path target/native-macos/swift
dotnet run --project apps/windows/Wisp.ProjectBrowser.ContractTests -- contracts/project-browser/v1/projects.json
```

The Native Preview workflow runs the Swift build/tests on macOS and the C#
contract check plus Rust service tests on Windows. Tests use temporary databases,
shared JSON fixtures, and a fake child process; no API key, remote host, or model
is required. Swift presentation tests cover filtered selection, project identity,
both palettes, and native SVG loading for the bundled wordmarks/icons.

Manual smoke steps:

1. Launch the built app and confirm the real project names, starred ordering,
   counts, descriptions, and paths agree with the desktop.
2. Search for a project, select it, and use Finder reveal. Missing directories
   should show an explanation and disable reveal.
3. Refresh after a desktop metadata change. Verify selection remains on the
   same project ID; duplicate workspace paths remain separate projects.
4. Open the database chooser and immediately press Escape. Only the system
   chooser should close; the browser should remain open.
5. Select an incompatible database and confirm the error is visible. Relaunch
   or refresh with a valid database and verify recovery.
6. Toggle the star filter and search until no results remain. Confirm no hidden
   project is left in the overview. Clear the filters and confirm recovery.
7. Compare the native page with the WebView project landing page in light and dark
   appearance. Resize below 820 points: header actions wrap and columns stack,
   while project paths and controls remain accessible. Open the appearance menu
   then press Escape immediately; the window should remain open.

Follow-up work: extract shared session services, supply live runtime snapshots,
add version/capability negotiation for a broader native API, implement the WinUI
transport and UI, and define native signing/distribution. This preview adds no
chat execution, project creation, migration ownership, or IPC daemon lifecycle.
