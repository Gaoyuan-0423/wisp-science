# Find in a conversation

Press **Ctrl+F** on Windows/Linux or **Command+F** on macOS while viewing the
conversation to search its displayed message bodies. The count and orange
active highlight use the same ordered list of matches; yellow highlights show
the other matches. Sidebar labels, session titles, composer text and hidden
content are excluded. Matching is literal and case-insensitive, including text
split by inline Markdown formatting.

**Enter** / **Shift+Enter** and the next/previous arrows move through matches,
wrapping at either end. Navigation pauses automatic following of new output,
so a result reached from the bottom remains visible. **Back to latest** resumes
following. **Escape** closes the find bar after any overlaid dialog or menu;
closing find preserves the reading position. Changing sessions closes find.

Search covers the currently displayed transcript window. Load older messages
to search that window; the count refreshes when displayed content changes.
Collapsed content is searchable after expanding it. Editors and terminals keep
their own find shortcuts when focused.
Older WebViews without the CSS Highlight API retain their native find UI.

## Finding older questions after compaction

The conversation outline lists the saved visual history, including questions
that are no longer part of the model's compacted context. Its count does not
depend on which message page is currently displayed. Context summary
checkpoints are not counted as questions.

Choose a question in the outline to load and scroll to it. When an old message
cursor cannot be used safely after compaction, Wisp walks saved history pages
until it finds that question. Loading failures are shown and the selection can
be retried. Scrolling upward also loads earlier pages. This restores access to
persisted history; it cannot reconstruct events that were never saved.
