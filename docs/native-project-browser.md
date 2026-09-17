# Native project browser preview

Wisp now has a small SwiftUI project browser alongside the existing Tauri client.
It lists real projects, preserves the desktop's ordering and metadata, searches
names/descriptions/paths, refreshes on demand, and reveals a selected workspace
in Finder. Project-card stars now persist through the shared Rust service and
reorder the list exactly like the WebView. The existing desktop remains the client
for chat and execution.

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

CI and the app build check for asset drift. WinUI can consume the same SVG and
palette exports when its views are implemented. Native system font rendering,
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

Queries open SQLite read-only. Clicking a project-card star explicitly launches
`wisp-service --database <path> --allow-project-writes` and sends the desired
Boolean state. Only that command opens an existing writable connection; it does
not create a database, run migrations, change journal mode, access credentials,
or execute tools. Database selection and refresh remain queries.

Stars are local project metadata shared with the WebView. They do not touch
activity timestamps, workspace files, or selected sessions. While saving, star
buttons, refresh, and database selection are disabled to prevent competing
updates. The UI applies the server's ordered snapshot only after success. Failures
preserve the previous display and show an error; refresh to confirm the persisted
state if a response was lost. Repeating the same desired state is idempotent.

Databases from before project stars are readable without migration, with projects
treated as unstarred. Attempting to save a star explains that the current WebView
desktop must upgrade the database first. Other incompatible older schemas may
fail to query. SQLite may use ordinary WAL/SHM coordination files when a desktop
writer is also active. Native star writes do not push events to an already-open
WebView; refresh its home list to see the change (and vice versa).

## Status semantics

The standalone preview has no access to the desktop's in-memory Agent and
approval state. Responses explicitly declare `activity_source: persisted_only`.
The UI shows saved session/artifact counts, saved unread replies, and sync
metadata; it labels live execution and approval status as unavailable. A zero
`running_count` in this mode must **not** be presented as proof that no work is
running. Failed refreshes retain the last successful snapshot with its timestamp
and an error banner; selecting a different database clears the old snapshot.

## Shared boundary and WinUI 3 seam

- `wisp-app::projects` owns project-list queries, activity enrichment, and the project-star command. The
  existing Tauri command calls the same service with real runtime snapshots.
- `wisp-dto::project_browser` owns the native protocol shapes.
- `wisp-service --database <path>` exposes those queries over stdin/stdout JSONL.
- `apps/macos` contains a Foundation transport client and SwiftUI presentation.
- `apps/windows/Wisp.ProjectBrowser.Contracts` provides `IProjectBrowserClient`
  and C# response/project/session/transcript/command DTOs for a future WinUI 3 view model. It intentionally
  contains no WinUI window or transport implementation yet.
- `contracts/project-browser/v1/{projects,sessions,transcript,set-project-starred}.json` are decoded by Rust, Swift, and
  the C# contract smoke test to detect wire-format drift.

The UI never queries SQLite directly. The macOS adapter starts one short-lived
service per request and closes stdin after one request. The service also accepts
multiple requests per process, enabling a future persistent Windows adapter.

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
`capabilities` response contains `commands` and `read_only: true` by default.
With `--allow-project-writes`, it additionally advertises `set_project_starred`
and `read_only: false`. The additive v1 command is:

```json
{"schema":"wisp.project-browser.v1","id":"projects-1","type":"set_project_starred","project_id":"project-id","starred":true}
```

Success returns the same ordered `projects` response as `list_projects`. Without
explicit write mode it returns `write_disabled`. An `error`
response contains `code` (`invalid_request`, `unsupported_schema`, or
`query_failed`, `write_disabled`, or `command_failed`) and `message`. Malformed requests have `id: null`. Stdout carries
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

1. Compare home project ordering and the five recent sessions with the WebView.
2. Click a project: verify the left session list and main conversation pane.
3. Return home and click a recent session: verify the exact project/session opens.
4. Switch sessions, switch projects, collapse/reopen the sidebar, and return home
   while a query is loading. Old responses must not reopen a previous workspace.
5. Load older messages in a long conversation and confirm no duplicated rows.
6. Open home search, appearance/project menus, or the database chooser, then
   immediately press Escape. Only the topmost surface should close.
7. Check light/dark themes and narrow windows. Refresh and directory reveal must
   still work. Failed queries must offer visible errors rather than blank content.
8. On a disposable database, star an older project: it moves ahead of unstarred
   projects, without opening its workspace. Unstar and verify the original order.
   Refresh/relaunch and compare with WebView; activity timestamps must not change.
9. Try a legacy database without the `starred` column: reads work; a star click
   shows an upgrade error without changing schema or the visible snapshot.

## Shell alignment checks

| WebView surface | Native preview |
| --- | --- |
| Home header | Same calendar/library/search/settings/scratch/import/new-project order; search is connected. |
| Home content | Projects left, five recent sessions right; cards navigate into a workspace. |
| Project shell | Back/project switch/collapse at the top of the left sidebar, navigation above saved sessions, utility entries below. |
| Session controls | Selection and sorting/grouping retain their positions; not connected yet. |
| Conversation | Session title and action strip above, scrollable saved transcript in the center, composer position below. |
| Search | Home/project scope, Up/Down and Enter navigation, topmost Escape, Command-K even with the sidebar collapsed. |
| Preview utilities | Database selection, refresh and appearance remain in the footer; these do not replace WebView actions. |

## Remaining feature work

The preview aligns the home/workspace shell and read-only navigation. Full
feature parity remains separate from this layout change. Home creation/import,
calendar/library/settings entry points, the sidebar tools, artifact
search, and composer/live runtime integration still require their native services.
Their action slots are visible but explicitly disabled in the preview.
The transcript currently renders saved text and tool records, not the WebView's
rich attachments, branch/review cards, or interactive tool surfaces. WinUI retains
the expanded contract seam; its transport/window, native signing/distribution,
and richer capability negotiation remain follow-ups. Conversations remain read-only.
