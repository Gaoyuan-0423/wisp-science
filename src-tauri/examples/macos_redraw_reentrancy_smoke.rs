//! Real macOS regression for #1250. Uses a disposable native Tao window, no
//! project DB, WebView, external service, or the user's app process.
//! Run: cargo run -p wisp-tauri --example macos_redraw_reentrancy_smoke
//! Add --control for display outside a Tao user-event callback; --sheet opens
//! a native save panel, forces a parent-view redraw, then cancels it.
//! --hold delays failure for a dump.

#[cfg(not(target_os = "macos"))]
fn main() {
    println!("SKIP: macOS redraw reentrancy regression");
}

#[cfg(target_os = "macos")]
fn main() {
    macos_smoke::run();
}

#[cfg(target_os = "macos")]
mod macos_smoke {
    use std::ffi::c_void;
    use std::mem;
    use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
    use objc2::{msg_send, sel};
    use tao::dpi::LogicalSize;
    use tao::event::{Event, StartCause};
    use tao::event_loop::{ControlFlow, EventLoopBuilder};
    use tao::platform::macos::WindowExtMacOS;
    use tao::window::WindowBuilder;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct NSRect {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    }

    #[derive(Debug, Clone, Copy)]
    enum Command {
        TriggerDisplay,
        OpenPanel,
    }

    static VIEW: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    static PANEL: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    static ORIGINAL_DRAW_RECT: AtomicPtr<()> = AtomicPtr::new(std::ptr::null_mut());
    static READY: AtomicBool = AtomicBool::new(false);
    static IN_OUTER: AtomicBool = AtomicBool::new(false);
    static DRAW_DURING_OUTER: AtomicBool = AtomicBool::new(false);
    static USER_EVENT_DONE: AtomicBool = AtomicBool::new(false);
    static DELAYED_REDRAW: AtomicBool = AtomicBool::new(false);
    static REENTRANT_DISPATCH: AtomicBool = AtomicBool::new(false);
    static DRAW_COUNT: AtomicUsize = AtomicUsize::new(0);
    static HOLD_ON_FAILURE: AtomicBool = AtomicBool::new(false);

    fn fail(message: &str) -> ! {
        eprintln!("FAIL: {message}");
        if HOLD_ON_FAILURE.load(Ordering::SeqCst) {
            eprintln!(
                "Holding disposable process {} for a dump (15 seconds)",
                std::process::id()
            );
            std::thread::sleep(Duration::from_secs(15));
        }
        // A deliberately deadlocked test UI cannot execute EventLoop exit.
        // Terminate only this disposable smoke process from its worker thread.
        std::process::exit(1);
    }

    fn wait_flag(flag: &AtomicBool, timeout: Duration, message: impl FnOnce() -> String) {
        let start = Instant::now();
        while !flag.load(Ordering::SeqCst) {
            if start.elapsed() > timeout {
                fail(&message());
            }
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    extern "C" fn hooked_draw_rect(this: *mut AnyObject, selector: Sel, rect: NSRect) {
        DRAW_COUNT.fetch_add(1, Ordering::SeqCst);
        if IN_OUTER.load(Ordering::SeqCst) {
            DRAW_DURING_OUTER.store(true, Ordering::SeqCst);
            println!("DRAW: TaoView drawRect during outer callback");
        }
        let original = ORIGINAL_DRAW_RECT.load(Ordering::SeqCst);
        let original: unsafe extern "C" fn(*mut AnyObject, Sel, NSRect) =
            unsafe { mem::transmute(original) };
        unsafe { original(this, selector, rect) };
    }

    fn install_draw_hook() {
        let class = AnyClass::get(c"TaoView").unwrap_or_else(|| fail("TaoView class is missing"));
        let method = class
            .instance_method(sel!(drawRect:))
            .unwrap_or_else(|| fail("TaoView is missing drawRect:"));
        let hooked: Imp = unsafe { mem::transmute(hooked_draw_rect as *const ()) };
        let previous = unsafe { method.set_implementation(hooked) };
        ORIGINAL_DRAW_RECT.store(previous as *mut (), Ordering::SeqCst);
        println!("HOOK: replaced TaoView drawRect:");
    }

    fn view_object() -> *mut AnyObject {
        let view = VIEW.load(Ordering::SeqCst);
        if view.is_null() {
            fail("NSView pointer is missing");
        }
        view as *mut AnyObject
    }

    fn display_view() {
        let view = view_object();
        let _: () = unsafe { msg_send![view, setNeedsDisplay: true] };
        let _: () = unsafe { msg_send![view, display] };
    }

    fn display_view_from_worker() {
        let view = view_object();
        let _: () = unsafe {
            msg_send![
                view,
                performSelectorOnMainThread: sel!(display),
                withObject: std::ptr::null_mut::<AnyObject>(),
                waitUntilDone: true
            ]
        };
    }

    fn reset_case_flags() {
        DRAW_COUNT.store(0, Ordering::SeqCst);
        DRAW_DURING_OUTER.store(false, Ordering::SeqCst);
        DELAYED_REDRAW.store(false, Ordering::SeqCst);
        REENTRANT_DISPATCH.store(false, Ordering::SeqCst);
        USER_EVENT_DONE.store(false, Ordering::SeqCst);
        IN_OUTER.store(false, Ordering::SeqCst);
    }

    fn status() -> String {
        format!(
            "draw_during_outer={}, delayed={}, reentrant_dispatch={}, draw_count={}",
            DRAW_DURING_OUTER.load(Ordering::SeqCst),
            DELAYED_REDRAW.load(Ordering::SeqCst),
            REENTRANT_DISPATCH.load(Ordering::SeqCst),
            DRAW_COUNT.load(Ordering::SeqCst),
        )
    }

    pub(super) fn run() {
        let arguments: Vec<_> = std::env::args().skip(1).collect();
        let control = arguments.iter().any(|arg| arg == "--control");
        let sheet = arguments.iter().any(|arg| arg == "--sheet");
        HOLD_ON_FAILURE.store(
            arguments.iter().any(|arg| arg == "--hold"),
            Ordering::SeqCst,
        );
        if control && sheet {
            fail("use either --control or --sheet");
        }

        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(45));
            fail("native redraw regression exceeded its deadline");
        });

        let event_loop = EventLoopBuilder::<Command>::with_user_event().build();
        let proxy = event_loop.create_proxy();
        let window = WindowBuilder::new()
            .with_title("Wisp disposable redraw smoke")
            .with_visible(true)
            .with_inner_size(LogicalSize::new(80.0, 80.0))
            .build(&event_loop)
            .unwrap_or_else(|err| fail(&format!("failed to create native window: {err}")));
        VIEW.store(window.ns_view(), Ordering::SeqCst);
        install_draw_hook();

        std::thread::spawn(move || {
            wait_flag(&READY, Duration::from_secs(5), || {
                "event loop never became ready".into()
            });
            // Let the first mapping/redraw pass finish before arming counters.
            std::thread::sleep(Duration::from_millis(200));
            reset_case_flags();
            println!(
                "START: reentry={}, control={}, sheet={}, pid={}",
                !control && !sheet,
                control,
                sheet,
                std::process::id()
            );

            if control {
                display_view_from_worker();
                if DRAW_COUNT.load(Ordering::SeqCst) == 0 {
                    fail("control display did not enter TaoView drawRect:");
                }
                println!(
                    "PASS: serial display completed, draw_count={}",
                    DRAW_COUNT.load(Ordering::SeqCst)
                );
                std::process::exit(0);
            }

            let command = if sheet {
                Command::OpenPanel
            } else {
                Command::TriggerDisplay
            };
            if proxy.send_event(command).is_err() {
                fail("failed to queue user event");
            }
            wait_flag(&USER_EVENT_DONE, Duration::from_secs(8), || {
                format!("user-event display timed out; {}", status())
            });
            wait_flag(&DELAYED_REDRAW, Duration::from_secs(5), || {
                format!("queued RedrawRequested was not delivered; {}", status())
            });
            if !DRAW_DURING_OUTER.load(Ordering::SeqCst) {
                fail("display did not enter TaoView drawRect: during the outer callback");
            }
            if REENTRANT_DISPATCH.load(Ordering::SeqCst) {
                fail("RedrawRequested was dispatched reentrantly inside the outer callback");
            }
            println!(
                "PASS: reentrant display completed, delayed RedrawRequested delivered, draw_count={}",
                DRAW_COUNT.load(Ordering::SeqCst)
            );
            std::process::exit(0);
        });

        event_loop.run(move |event, _, control_flow| {
            *control_flow = ControlFlow::Wait;
            match event {
                Event::NewEvents(StartCause::Init) => {
                    READY.store(true, Ordering::SeqCst);
                    println!("READY: tao event loop init");
                }
                Event::UserEvent(Command::TriggerDisplay) => {
                    IN_OUTER.store(true, Ordering::SeqCst);
                    println!("USER: calling display inside user-event callback");
                    display_view();
                    IN_OUTER.store(false, Ordering::SeqCst);
                    USER_EVENT_DONE.store(true, Ordering::SeqCst);
                    println!("USER: display returned");
                }
                Event::UserEvent(Command::OpenPanel) => {
                    let class = AnyClass::get(c"NSSavePanel")
                        .unwrap_or_else(|| fail("NSSavePanel class is missing"));
                    let panel: *mut AnyObject = unsafe { msg_send![class, savePanel] };
                    if panel.is_null() {
                        fail("NSSavePanel.savePanel returned nil");
                    }
                    let _: *mut AnyObject = unsafe { msg_send![panel, retain] };
                    PANEL.store(panel as *mut c_void, Ordering::SeqCst);
                    std::thread::spawn(|| {
                        std::thread::sleep(Duration::from_millis(150));
                        println!("SHEET: forcing parent display during nested save-panel loop");
                        display_view_from_worker();
                        let panel = PANEL.load(Ordering::SeqCst) as *mut AnyObject;
                        if panel.is_null() {
                            fail("save panel pointer is missing");
                        }
                        let _: () = unsafe {
                            msg_send![
                                panel,
                                performSelectorOnMainThread: sel!(cancel:),
                                withObject: std::ptr::null_mut::<AnyObject>(),
                                waitUntilDone: true
                            ]
                        };
                    });
                    IN_OUTER.store(true, Ordering::SeqCst);
                    println!("USER: running NSSavePanel modal session");
                    let _: isize = unsafe { msg_send![panel, runModal] };
                    IN_OUTER.store(false, Ordering::SeqCst);
                    USER_EVENT_DONE.store(true, Ordering::SeqCst);
                    println!("USER: save panel modal session returned");
                }
                Event::RedrawRequested(_) if USER_EVENT_DONE.load(Ordering::SeqCst) => {
                    DELAYED_REDRAW.store(true, Ordering::SeqCst);
                    println!("REDRAW: delivered after outer callback");
                }
                Event::RedrawRequested(_) if IN_OUTER.load(Ordering::SeqCst) => {
                    REENTRANT_DISPATCH.store(true, Ordering::SeqCst);
                    println!("REDRAW: dispatched during outer callback");
                }
                _ => {}
            }
        });
    }
}
