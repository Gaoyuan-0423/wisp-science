# Native workspace toolbar parity

The target is the seven WebView conversation toolbar actions, in the existing
order, implemented as SwiftUI surfaces with shared native contracts for WinUI 3.
The WebView remains supported. This work is in progress; enabled icons alone do
not establish parity.

## Acceptance checklist

- [ ] Conversation outline: full persisted question index, search, historical
  navigation, repeated-prompt correctness, live updates, timestamps and timings;
  verify Escape immediately after opening.
- [ ] Share: selectable and editable/redactable user/assistant/thinking messages,
  thinking initially excluded, export preview, HTML and PNG export, PNG width
  selection. Social-copy/highlight flows are hidden in current WebView (see
  `ui/src/overlays.rs::ShareOverlay` and test-only helpers in `app_support/share.rs`).
- [ ] Trajectory: existing recorded turns, tool details, timing/token statistics,
  filters and export; no derived fake runtime data.
- [ ] Research archive: load/prepare draft, edit report/scripts, review file
  actions, explicit consent before freeze/cleanup, inspect frozen materials,
  retry cleanup and continue research. Preserve backend ownership checks.
- [ ] Needs-you inbox: current cross-project entries, badges, navigation to the
  correct project/session, seen state and refresh.
- [ ] Terminal: project/context-owned persistent PTY sessions, local and remote
  context selection, output/input, resize, interrupt, close and reconnect;
  separate native workspace authorization from ACP authentication terminals.
- [ ] Right panel: toggle and persist selected tabs; artifacts, agents, files,
  execution contexts plus the existing optional notebook, highlights, provenance
  and side-chat surfaces. Match WebView behavior and actual data sources.
- [ ] Shared DTOs, Swift and C# clients and fixtures; backwards compatibility.
- [ ] Tests for navigation races, project/session ownership, topmost Escape,
  empty/error/reconnect states; rendered desktop/narrow/dark layouts.
- [ ] Full repository verification and updated reviewable PR.

## Implemented foundation

`native_conversation_outline` validates the project/session owner, flushes saved
conversation events and returns the full persisted question index. Each entry
contains its global question index, text, timestamps and the next question's
exclusive transcript cursor. Snapshot `user_offset` is additive and allows a
client to locate identical prompts without text matching. Older hosts omit this
field; native navigation reports a refresh/upgrade error instead of guessing.
SwiftUI has a searchable outline popover and history navigation. WinUI has the
same outline method and DTO. Remaining acceptance items above still apply.

## Current verification

The focused Swift conversation and outline suite passes (11 tests), covering
history cursor routing and global question indexes for repeated prompts. The
C# contract executable passes with the shared outline fixture. Rust check and
DTO tests are running; full checks, Escape interaction testing and visual QA
are still outstanding. No completion or full parity claim is made yet.

## Trajectory and inbox implementation

The trajectory button opens a native sheet with recorded turns, searchable
inputs/outputs, token and timing statistics, a step inspector and HTML export.
`native_conversation_trajectory` uses the existing trajectory fold;
`native_conversation_trajectory_html` uses the same HTML renderer as WebView,
while SwiftUI owns the save dialog. C# exposes both operations. The current bar
visualization still needs comparison with WebView's lane/time-axis behavior;
visual equivalence and immediate topmost Escape have not yet been verified.

The inbox button shows the same 50-session cross-project search and needs-you
filter as WebView, polls every 20 seconds, refreshes on opening, and navigates
using both project and session IDs. `native_conversation_seen` validates ownership
and marks a successfully opened session seen. Failed reads do not mark it seen.
C# exposes inbox and mark-seen operations with the existing SessionSearchInfo
shape. Live app interaction and badge refresh after opening still need smoke QA.

Latest focused Swift run: 15 passed, one opt-in render test skipped. Coverage
includes repeated prompt history positioning, trajectory scope/search/export,
inbox failure preservation and marking only successfully read sessions seen.
Rust compilation remains running; it must be rerun for the final changed tree.
The right-side panel is enabled for artifacts and files; its other tabs remain pending.


## Research archive implementation

SwiftUI now loads/prepares the existing archive draft and supports report/script
editing, file action selection, explicit consent, immutable freeze and cleanup,
cleanup retry and continuation. Editing clears consent. A failed confirm reloads
the saved record once without replaying a mutation, including when cleanup failed
after a successful freeze. Saved materials open in a child Quick Look preview;
canonical paths must remain inside the selected workspace. The existing backend
still verifies ownership, file checksums, writable scope and deletion eligibility.
The C# `INativeArchiveClient` uses the same ResearchArchive and confirmation DTOs.

Archive tests cover scope, confirmation fields, consent invalidation and failed
cleanup reconciliation/no replay. Three behavior tests passed; the opt-in renderer
also passed and desktop/narrow/dark output was inspected. A missing explicit
surface background was fixed during visual inspection. Final preview integration
compiled and behavior tests passed again. Actual Escape/topmost interaction and
real app smoke remain unverified; no live user research was archived during QA.
C# shared fixture verification passed. The initial Rust check completed, and a
second Rust check including archive changes is running; full CI remains pending.


## Share implementation

The native share sheet now loads full history in bounded transcript pages,
selects user/assistant rows by default, excludes reasoning by default, supports
editing the export copy, select-all/none, case-insensitive keyword masking,
preview, width selection (320–2400, default 840), and HTML/PNG file export.
Only edited/redacted selected rows are submitted for HTML generation. The host
validates session ownership and renders HTML using the existing standalone
WebView export stylesheet with escaped raw HTML and restricted link schemes.
PNG uses the actual SwiftUI preview at one pixel per requested width unit.
Images over 40 million pixels or 32768 pixels tall produce an explicit error
with HTML as an alternative; transcript sharing is capped at 16 MiB.

The original acceptance draft incorrectly included social-copy/highlight flows:
source inspection shows these are test-only/hidden in the current WebView.
Visible ShareOverlay has PNG and HTML export only, which remains the target.

Four focused Swift tests passed, including redaction/default selection, width,
Markdown block preservation and actual PNG pixel dimensions. The redacted PNG
was inspected. C# fixture/client compilation passed. Native PNG currently covers
paragraphs, headings, bullets, quotes and fenced code; tables and complex nested
Markdown layout still need alignment and must not be considered complete.
Rust share-render tests are running. Full runtime/Escape smoke and all-suite
verification remain outstanding.


## Terminal implementation

The terminal button now opens a resizable native dock. An empty dock opens the
local execution context once; existing PTYs reappear on reopening. Additional
terminals use registered execution contexts (local/WSL/OpenSSH through the
existing launch implementation). Hide detaches the view without closing the
process. Closing a terminal tab terminates and unregisters it.

The authenticated native commands validate project and frame scope on every
operation, exclude ACP authentication terminals, and require writable scope for
open/write/resize. Reads return base64 raw bytes with absolute start/end cursors;
bounded scrollback resets are explicit. The frontend uses SwiftTerm 1.19.0's
AppKit control for VT/ANSI, selection, keyboard and alternate-screen behavior.
Input is serialized, never automatically replayed, and uncertain input pauses
queued bytes until the user explicitly resumes. C# INativeTerminalClient exposes
the same raw-byte boundary for a future WinUI terminal control.

SwiftTerm is pinned by Package.resolved and its MIT notice is included in the UI
resource bundle. Packaging copies its resource bundle and adds the SwiftPM lookup
symlink. Xcode's Metal Toolchain component is required by its packaged shaders;
install via `xcodebuild -downloadComponent MetalToolchain` when absent. The local
component was installed and the default Swift build then passed; the temporary
native-build-system workaround is not required by project scripts.

Three focused Swift tests passed: byte cursor validation, no replay of uncertain
queued input, and real native emulator cursor/alternate-screen handling. The ANSI
output bitmap was inspected. C# fixture/client verification passed. The scoped
native PTY lifecycle Rust test passed. Reconnect under high-volume rollover,
live app keyboard/resize, cross-platform runtime smoke and full-suite checks are
still pending; SSH/WSL tests must continue to use mocks, not real hosts.


## Side-panel foundation

The seventh toolbar action now toggles a native, width-adjustable panel and
persists visibility and selected tab. Artifacts and local files are connected:
name filtering, directory/parent navigation, file sizes, scoped artifact reads,
text and Quick Look previews, truncation notices, and refresh. Quick Look is
shared with archive material previews. No preview executes a file.

`native_conversation_panel_*` resolves the requested frame to its actual working
project and state scope, validates artifact visibility, and reuses existing
file boundary/preview logic; it never depends on a shared hidden window's current
frame. Swift/C# use existing ArtifactInfo/DirEntry/FileContent shapes. Focused
Swift tests for late directory responses and truncated preview metadata and C#
fixtures passed. The Rust file-boundary integration test passed after adding
the missing tempfile test dependency.

This is not side-panel parity yet: agent workflows, advanced execution controls, optional
notebook/highlights/provenance/side-chat tabs, tab add/close/reorder state, remote
file operations, editing/download/actions and full visual/Escape QA remain to be
implemented/verified. Their absence must not be treated as task completion.


## Session execution contexts

The native right panel now includes Execution Environments. It shows the local
context plus contexts attached to the current conversation, with status, probe
errors and expandable machine capabilities. Available contexts can be attached;
nonlocal contexts can be detached. Probe uses the existing settings command and
runs only on explicit user action. No test contacts a remote machine.

The shared `PanelContexts` response uses the existing ExecutionContext fields,
conversation membership and a read-only flag. Membership mutations validate
project/session ownership, existing context identity, archive state and writable
scope. Swift and C# clients share `panel-contexts.json`; uncertain writes are not
replayed. Read-only views disable attachment changes. A reply arriving after
navigation cannot trigger a stale context refresh.

Swift behavior tests cover session filtering, read-only controls and mutation
failure without replay. C# contract tests passed. The 280-point light/dark cards
were rendered and inspected. The latest full native suite passed (60 tests,
three opt-in render tests skipped); all five panel tests also passed with
rendering enabled. The Rust file-boundary integration test and ten shared native
DTO tests passed. Formatting checks passed. Full Rust workspace, WebView and
packaged-app verification remain pending.

Runtime management, run lists, interpreter/storage editors and context terminal
shortcuts still need to be integrated in this panel. Existing native settings
remain available for configuration. Agents, optional tabs and tab management
remain pending; this addition does not complete the side-panel acceptance item.

## Runtime and run activity panels

Execution-context cards now open native runtime and run sheets. Runtime rows show
language, status, interpreter/version, process memory and last error, with variable
inspection. The backend reuses WebView's runtime visibility predicate: the active
conversation and shared runtimes are visible, other mainline projects remain
visible for resource awareness, and exploration scopes exclude foreign sessions.
No hidden window's active frame is used.

Run lists reuse scoped RunSummary data and load only the selected RunRecord's
command/output/error details. Lists poll while open. Users can cancel a live run
with confirmation or retry harvesting a successful run's outputs. These commands
use the existing RunManager, require an unarchived writable conversation and
reject mutation of inherited or foreign-scope runs. No mutation is retried on a
lost reply. A failure stays visible across polling; dismissing details invalidates
late replies. Refresh does not flash a full loading indicator on every poll.

`PanelActivity` reuses wisp-dto RuntimeInfo/RunSummary, preserving the runtime
camelCase wire format and the run snake_case format. Swift and WinUI-facing C#
clients share activity, run-detail and variable fixtures. All 63 native tests
passed with opt-in rendering enabled; C# contract checks and 11 native DTO tests
passed. Runtime/list/detail screenshots were inspected. Both Rust panel tests
passed, including rejection of foreign-project and missing run IDs for reads and
mutations. A separate run of the reused runtime-visibility tests is in progress.

Remaining within this area: runtime start/stop/restart, console execution,
interpreter/storage controls, full run workspace/file review and cleanup, and
live topmost-Escape interaction verification. These sheets are not yet full
WebView runtime/run parity. All other outstanding toolbar acceptance items remain
in scope.
