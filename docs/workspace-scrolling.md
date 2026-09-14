# Workspace scrolling

The desktop viewport and its three shell columns do not scroll. Only inner
conversation, session-list, artifact-list, file and agent content areas scroll;
project/session headers and right-panel tabs remain visible. Shell clipping uses
`overflow: clip` because `overflow: hidden` still permits programmatic scrolling
from focus and `scrollIntoView`; the body is fixed to the viewport so document
scrolling cannot move all three headers together.

Conversation jumps scroll the conversation container explicitly. Opening or switching
conversations starts at the latest message and resets the mounted right-panel
lists to the top. Scrolling up within the open conversation still preserves the
current reading position as new content arrives.

Manual check on Windows WebView2 and macOS: open two long conversations with
many artifacts, scroll each column to the bottom, switch sessions repeatedly,
and use conversation outline jumps. All three headers must stay visible and
Artifacts/Agents/Files must remain clickable. Repeat with the artifact preview
hidden, a small window, and a large file preview.
