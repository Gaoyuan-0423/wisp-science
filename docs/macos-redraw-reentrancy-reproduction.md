# macOS redraw deadlock reproduction (#1250)

On 2026-09-17 the published `tao 0.37.0` dependency reproduced a native UI
deadlock in a disposable window. Wisp now vendors that crate with a
`handle_redraw` reentry guard. The example is retained as a native macOS
regression and runs in CI with the locked desktop dependency chain.

Issue: <https://github.com/xuzhougeng/wisp-science/issues/1250>.
Related Windows input deadlock: <https://github.com/xuzhougeng/wisp-science/issues/1265>.

## Recorded baseline (before the fix)

The isolated native reproducer ran on macOS 26.6.2 / arm64 against unmodified
crates.io `tao 0.37.0`. Each trial started a fresh process.

| Scenario | Trials | Result |
| --- | ---: | --- |
| Serial `-[NSView display]` from a worker via `performSelectorOnMainThread` | 1 | Returned successfully |
| `-[NSView display]` inside a Tao user-event callback | 1 | Deadlock / display timeout, exit 1 |

The deadlock trial printed `TaoView drawRect during outer user-event callback`
and then never returned from `display`. Timeout is eight seconds after sending
the user event. A matching-symbol `sample` of that process identifies the
callback mutex self-wait below.

After the `handle_redraw` guard, the same machine (macOS 26.6.2 / arm64)
and locked desktop tree completed:

| Scenario | Trials | Result |
| --- | ---: | --- |
| Reentrant `display` inside a Tao user-event callback | 5 | 5/5 exit 0; `drawRect:` during outer callback; delayed `RedrawRequested` delivered |
| Serial `display` from a worker | 5 | 5/5 exit 0 |
| `NSSavePanel runModal` nested loop plus forced parent-view redraw | 5 | 5/5 exit 0; `drawRect:` during outer callback; delayed `RedrawRequested` delivered |

## Mechanism and stack evidence

The `macos_redraw_reentrancy_smoke` example creates one disposable **native**
Tao window and replaces `TaoView`'s `drawRect:` only in its own process. It
does not create a WebView, read the user's database, load a project, or
contact services.

A worker posts a user event. Tao's run-loop observer `cleared` holds
`HANDLER.callback` while dispatching that event. The event callback marks the
Tao `NSView` dirty and calls `display`. AppKit synchronously enters
`TaoView::draw_rect`, which calls `AppState::handle_redraw` →
`handle_nonuser_event` → the same non-recursive mutex.

The symbolized stack, shortened from outer caller to current wait, is:

```text
tao::event_loop::EventLoop::run
  -[NSApplication run]
    tao::observer::control_flow_end_handler
      AppState::cleared
        EventLoopHandler::handle_user_events          [outer callback owns the lock]
          smoke UserEvent handler
            -[NSView displayIfNeeded]
              ... AppKit / CoreAnimation flush ...
                tao::view::draw_rect
                  Handler::handle_nonuser_event
                    std::sys::pal::unix::sync::mutex::Mutex::lock
                      pthread_mutex_firstfit_lock_wait
                        __psynch_mutexwait
```

The source locations in Tao 0.37.0 are
`src/platform_impl/macos/app_state.rs` (`handle_user_events` at the callback
lock, `handle_redraw` without an `in_callback` guard) and
`src/platform_impl/macos/view.rs` (`draw_rect`). The same thread waits for a
non-reentrant lock held by its outer callback, which cannot return until the
inner `display` returns.

The original application's spindump had the same `main -> main` pattern around
an `NSSavePanel` sheet. It lacked matching dSYM symbols, so the reproducer's
function names must not be presented as symbolized frames from the original
app. The correspondence strongly supports this cause for the captured
incident; it does not identify every other reported hang.

## Fix

`handle_redraw` now matches `wakeup` / `cleared`: if `in_callback` is already
set, keep that outer guard and enqueue the window on the existing
deduplicated `queue_redraw` list. `cleared` drains that list after the outer
callback returns, so the `RedrawRequested` event is delayed rather than
dropped. The callback mutex is not made recursive.

## Running the reproducer

From the repository root:

```bash
export WISP_CATALOG_OFFLINE=1
cargo build --locked -p wisp-tauri --example macos_redraw_reentrancy_smoke

# Healthy control: display outside a Tao user-event callback; expected exit 0.
./target/debug/examples/macos_redraw_reentrancy_smoke --control

# Reentrant display from a user-event callback; expected exit 0 after the fix.
./target/debug/examples/macos_redraw_reentrancy_smoke

# Native save panel nested run loop plus a forced parent-view redraw.
./target/debug/examples/macos_redraw_reentrancy_smoke --sheet

# Leave a deadlocked process up for Activity Monitor / sample / LLDB.
./target/debug/examples/macos_redraw_reentrancy_smoke --hold
```
