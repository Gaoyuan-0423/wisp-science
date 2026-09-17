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
  thinking initially excluded, export preview, HTML and PNG export, highlights
  and social-copy workflows corresponding to the WebView.
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
Sharing, terminal and right-side panel are still disabled placeholders.


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
