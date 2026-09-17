# Native project browser preview

Wisp has SwiftUI (macOS) and WinUI 3 (Windows) project browsers alongside the existing Tauri client.
It lists real projects, preserves the desktop's ordering and metadata, searches
names/descriptions/paths, refreshes on demand, and reveals a selected workspace
in Finder or Explorer. The existing desktop remains the client for chat and execution.

## Visual alignment with the WebView

The SwiftUI landing page follows `ui/src/styles/projects.css`: a centered page
with the Wisp wordmark and tagline, warm paper surfaces, teal actions, compact
project cards, and two equal columns. Below 820 points it switches to one column;
long pages scroll. The right column now contains the same five recent saved
sessions as the WebView. Clicking a project enters its workspace; clicking a
recent session opens that exact conversation. The workspace has project switching,
a collapsible left session sidebar, a main transcript pane, and a back-to-projects
action. Saved transcripts load in pages of 20 user turns with an older-messages
control. Reading does not mark messages seen or change the WebView's active session.

The home search icon (Command-K) opens a dismissible search sheet for projects
and recent sessions. Up/Down selects a result and Enter opens it; filtering
resets selection. Escape closes only the topmost menu or search sheet, and IME
candidate selection keeps its keyboard handling. Inside a project, the same
search layer searches its saved conversations; Command-K also works with the
sidebar collapsed. Database selection and refresh live in the preview footer,
so they no longer occupy the WebView's primary project-action positions. The footer provides system/light/dark
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

CI and both app builds check for asset drift. WinUI links the same SVG and
palette files into its output. The exporter handles UTF-8 source and Windows CRLF checkouts. Native system font rendering,
window chrome, and file selection remain platform-specific; unsupported WebView
actions retain their WebView positions but are disabled and labeled as not yet connected.

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

## Build and run on Windows

Requires Windows 10 1809+ (x64), .NET 8+ SDK, Python 3, and the Rust toolchain.
The Windows App SDK and SDK build tools are restored from pinned NuGet packages;
Visual Studio's packaging workload is not required. From the repository root:

```powershell
pwsh -File scripts/build_native_windows.ps1 -Launch
```

Use `-Python C:/path/to/python.exe` if Python is not on PATH. The output is
`target/native-windows/Wisp.Science.Preview.exe` with its companion files.
The directory includes the .NET and Windows App SDK runtimes and `wisp-service.exe`;
copy the entire directory, not just the executable. This is an unsigned local x64
preview, not an installer or an update to the installed Tauri application.

The default database is `%APPDATA%/science.wisp-science/wisp-science/wisp.sqlite`.
The preview saves only its database selection and appearance in
`%LOCALAPPDATA%/WispSciencePreview/settings.json`. `WISP_BROWSER_DATABASE` and
`WISP_SERVICE_PATH` have the same meaning as on macOS. Ctrl+K opens home/project
search, Ctrl+R refreshes, and Ctrl+O opens the native file picker. The native
text context menu, project/appearance flyouts, search dialog and file picker
consume Escape from the topmost surface.

Windows uses device-independent layout units: at 150% scaling, a 1200-pixel
window is only 800 units wide. Home keeps independently scrolling project and
recent-session columns down to 680 units; below that they stack with separate
scroll areas. Home actions remain at the top right, wrapping within that corner
on smaller windows. The entire conversation action strip wraps to a second
right-aligned row instead of dropping entries at the compact breakpoint. A compact,
bounded sidebar tool area preserves room for sessions in short windows, with
preview utilities at its foot. The composer remains visibly disabled. Shared
icons and native controls are used throughout; there is no WebView in this client.

The Windows client starts a hidden process per query, drains stdout/stderr
concurrently, checks the full response envelope, and kills/reaps the process on
cancellation or a 20-second deadline. Output is bounded to 32 Mi characters and
stderr to 64 Ki characters. Failed refreshes retain the previous snapshot and
show an error; changing databases clears it. Independent refresh/navigation/
transcript generations prevent late queries reopening old projects or sessions.
Closing the window cancels active queries. Search is a compact native overlay
with a scope label, icon-bearing results, IME-aware keyboard navigation and no
large dialog footer. Saved transcript text is selectable; headings, lists,
emphasis, HTTP(S) links and code text render through Markdig and native XAML.
HTML stays inert and images are represented by alt text without downloading.
Tool results and the v1 service's name/JSON argument lines are collapsed behind
expanders; the full saved content remains available, with argument strings
decoded to show real Unicode and newlines. Rich attachments, tables, and
interactive tool execution surfaces remain follow-ups.

### Current Windows milestone and validation boundary

The Windows preview now implements the read-only home → project → saved-session
path established by PRs #1274 and #1276: recent-session deep links, project/session
selection, search, history pagination, database selection, refresh, themes and
Explorer reveal. Creation/import, chat submission, model selection, live runs,
approvals, and sidebar tool services are still disabled. This is an incremental
preview, not completed parity with the production WebView.

The first local visual pass verified real data, the two-column home, the usable
session list, initial search/project-menu Escape handling and latest-message
scroll restoration. User screenshot feedback led to a further top-right action
layout, compact search overlay, persistent narrow-window action strip and native
Markdown/tool folding. That build compiles and its final home was visually
rechecked. The final search overlay (including nested text-menu Escape and IME),
action-strip wrapping, tool expanders and Markdown still require a complete
manual pass; automated desktop control was stopped by the user. Do not treat
the earlier dialog checks as validation of the replacement overlay.

## Status semantics

The standalone preview has no access to the desktop's in-memory Agent and
approval state. Responses explicitly declare `activity_source: persisted_only`.
The UI shows saved session/artifact counts, saved unread replies, and sync
metadata; it labels live execution and approval status as unavailable. A zero
`running_count` in this mode must **not** be presented as proof that no work is
running. Failed refreshes retain the last successful snapshot with its timestamp
and an error banner; selecting a different database clears the old snapshot.

## Shared native boundary

- `wisp-app::projects` owns the project-list query and activity enrichment. The
  existing Tauri command calls the same service with real runtime snapshots.
- `wisp-dto::project_browser` owns the native protocol shapes.
- `wisp-service --database <path>` exposes those queries over stdin/stdout JSONL.
- `apps/macos` contains a Foundation transport client and SwiftUI presentation.
- `apps/windows/Wisp.ProjectBrowser.Contracts` provides `IProjectBrowserClient`
  and C# response/project/session/transcript DTOs.
- `apps/windows/Wisp.ProjectBrowser` contains the transport, testable navigation
  state and layout breakpoints; `Wisp.Science.Preview` provides the WinUI window.
- `contracts/project-browser/v1/{projects,sessions,transcript}.json` are decoded by Rust, Swift, and
  the C# contract smoke test to detect wire-format drift.

The UI never queries SQLite directly. Both adapters start one short-lived
service per query and closes stdin after one request. The service also accepts
multiple requests per process, enabling a future persistent adapter.

Each UTF-8 request is one JSON line, at most 64 KiB including its newline:

```json
{"schema":"wisp.project-browser.v1","id":"projects-1","type":"list_projects"}
{"schema":"wisp.project-browser.v1","id":"sessions-1","type":"list_sessions"}
{"schema":"wisp.project-browser.v1","id":"sessions-2","type":"list_sessions","project_id":"project-id"}
{"schema":"wisp.project-browser.v1","id":"transcript-1","type":"get_transcript","project_id":"project-id","session_id":"session-id","before_seq":null}
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
contract/transport/navigation checks, Rust service tests and full WinUI publish
on Windows, uploading the runnable Windows directory as an artifact. Tests use temporary databases,
shared JSON fixtures, and a fake child process; no API key, remote host, or model
is required. Swift presentation tests cover filtered selection, project identity,
both palettes, and native SVG loading for the bundled wordmarks/icons. C# tests
exercise Unicode/spaced paths, pipe pressure, malformed/mismatched envelopes,
service failures, deadline/cancellation process cleanup, exact-session navigation,
database changes during refresh, stale responses, pagination, DPI breakpoints and
lossless separation of tool arguments from ordinary prose.

Manual smoke steps:

1. Compare home project ordering and the five recent sessions with the WebView.
2. Click a project: verify the left session list and main conversation pane.
3. Return home and click a recent session: verify the exact project/session opens.
4. Switch sessions, switch projects, collapse/reopen the sidebar, and return home
   while a query is loading. Old responses must not reopen a previous workspace.
5. Load older messages in a long conversation and confirm no duplicated rows.
6. Open home search, appearance/project menus, or the database chooser, then
   immediately press Escape. Only the topmost surface should close.
7. Check light/dark themes and narrow windows. Refresh and directory reveal must
   still work. On Windows, check 1200×850 physical pixels at 150% scaling: recent
   sessions must remain beside projects and the session list must have usable height.
   Failed queries must offer visible errors rather than blank content.

## Shell alignment checks

| WebView surface | Native preview |
| --- | --- |
| Home header | Same calendar/library/search/settings/scratch/import/new-project order; search is connected. |
| Home content | Projects left, five recent sessions right; cards navigate into a workspace. |
| Project shell | Back/project switch/collapse at the top of the left sidebar, navigation above saved sessions, utility entries below. |
| Session controls | Selection and sorting/grouping retain their positions; not connected yet. |
| Conversation | Session title and action strip above, scrollable saved transcript in the center, composer position below. |
| Search | Home/project scope, Up/Down and Enter navigation, topmost Escape, Command-K / Ctrl+K even with the sidebar collapsed. |
| Preview utilities | Database selection, refresh and appearance remain in the home footer / Windows sidebar footer; these do not replace WebView actions. |

## Remaining feature work

The preview aligns the home/workspace shell and read-only navigation. Full
feature parity remains separate from this layout change. Home creation/import,
calendar/library/settings entry points, the sidebar tools, artifact
search, and composer/live runtime integration still require their native services.
Their action slots are visible but explicitly disabled in the preview.
The transcript currently renders saved text and tool records, not the WebView's
rich attachments, branch/review cards, or interactive tool surfaces. Native
signing/distribution and capability negotiation remain follow-ups. The preview
remains read-only; Windows Markdown is intentionally limited to native text
formatting, with no interactive HTML or attachment rendering.
