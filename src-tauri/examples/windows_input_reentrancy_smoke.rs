//! Real Win32 regression for #1265. Uses hidden native windows, no project DB,
//! WebView, external service, real keyboard input, or user's app process.
//! Run: cargo run -p wisp-tauri --example windows_input_reentrancy_smoke -- keydown
//! Add --control for serial input/focus messages; --hold delays failure for a dump.

#[cfg(not(windows))]
fn main() {
    println!("SKIP: Windows input reentrancy regression");
}

#[cfg(windows)]
fn main() {
    windows_smoke::run();
}

#[cfg(windows)]
mod windows_smoke {
    use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
    use std::time::{Duration, Instant};
    use windows::Win32::{
        Foundation::{HWND, LPARAM, LRESULT, WPARAM},
        System::Threading::GetCurrentThreadId,
        UI::WindowsAndMessaging::{
            CallNextHookEx, GetQueueStatus, SendMessageTimeoutW, SetWindowsHookExW,
            UnhookWindowsHookEx, CWPSTRUCT, QS_SENDMESSAGE, SMTO_BLOCK, WH_CALLWNDPROC, WM_CHAR,
            WM_KEYDOWN, WM_KEYUP, WM_KILLFOCUS, WM_NULL, WM_SYSCHAR,
        },
    };

    static TARGET: AtomicUsize = AtomicUsize::new(0);
    static OUTER_MESSAGE: AtomicU32 = AtomicU32::new(0);
    static ARMED: AtomicBool = AtomicBool::new(false);
    static SEND_FOCUS: AtomicBool = AtomicBool::new(false);
    static FOCUS_QUEUED: AtomicBool = AtomicBool::new(false);
    static FOCUS_DISPATCHED: AtomicBool = AtomicBool::new(false);
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
        // A deliberately deadlocked test UI cannot execute AppHandle::exit.
        // Terminate only this disposable smoke process from its worker thread.
        std::process::exit(1);
    }

    unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 {
            let message = &*(lparam.0 as *const CWPSTRUCT);
            if message.hwnd.0 as usize == TARGET.load(Ordering::SeqCst) {
                if message.message == WM_KILLFOCUS && FOCUS_QUEUED.load(Ordering::SeqCst) {
                    FOCUS_DISPATCHED.store(true, Ordering::SeqCst);
                }
                if message.message == OUTER_MESSAGE.load(Ordering::SeqCst)
                    && ARMED.swap(false, Ordering::SeqCst)
                {
                    SEND_FOCUS.store(true, Ordering::SeqCst);
                    let start = Instant::now();
                    // Queue a *sent* focus message before Tao handles the key.
                    // GetQueueStatus observes it without dispatching it; Tao's
                    // subsequent PeekMessageW will reenter its window callback.
                    while (GetQueueStatus(QS_SENDMESSAGE) >> 16) & QS_SENDMESSAGE.0 == 0 {
                        if start.elapsed() > Duration::from_secs(3) {
                            fail("focus message was not queued at the input boundary");
                        }
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    FOCUS_QUEUED.store(true, Ordering::SeqCst);
                    println!("QUEUED: sent WM_KILLFOCUS before Tao input processing");
                }
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }

    fn send(hwnd: usize, message: u32, value: usize) -> bool {
        unsafe {
            SendMessageTimeoutW(
                HWND(hwnd as *mut _),
                message,
                WPARAM(value),
                LPARAM(0x001e0001),
                SMTO_BLOCK,
                5000,
                None,
            )
            .0 != 0
        }
    }

    pub(super) fn run() {
        let arguments: Vec<_> = std::env::args().skip(1).collect();
        let control = arguments.iter().any(|arg| arg == "--control");
        HOLD_ON_FAILURE.store(
            arguments.iter().any(|arg| arg == "--hold"),
            Ordering::SeqCst,
        );
        let mut cases = vec![
            ("keydown", WM_KEYDOWN, 0x41),
            ("keyup", WM_KEYUP, 0x41),
            ("char", WM_CHAR, '中' as usize),
            ("syschar", WM_SYSCHAR, '文' as usize),
        ];
        if let Some(case) = arguments.iter().find(|arg| !arg.starts_with("--")) {
            cases.retain(|(name, _, _)| name == case);
            assert!(
                !cases.is_empty(),
                "case must be keydown, keyup, char or syschar"
            );
        }
        // Ensure even startup/hook failures have a bounded failure mode.
        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(45));
            fail("native input regression exceeded its deadline");
        });
        let mut context = tauri::generate_context!();
        context.config_mut().identifier = "science.wisp.input-reentrancy-smoke".into();
        context.config_mut().app.windows.clear();
        context.config_mut().build.dev_url = None;
        tauri::Builder::default()
            .setup(move |app| {
                let window = tauri::window::WindowBuilder::new(app, "input-smoke")
                    .title("Wisp disposable input smoke")
                    .visible(false)
                    .focused(false)
                    .build()?;
                let hwnd = window.hwnd()?.0 as usize;
                TARGET.store(hwnd, Ordering::SeqCst);
                let hook_handle = unsafe {
                    SetWindowsHookExW(WH_CALLWNDPROC, Some(hook), None, GetCurrentThreadId())?
                };
                let hook_id = hook_handle.0 as usize;
                let app = app.handle().clone();
                std::thread::spawn(move || {
                    for (name, message, value) in cases {
                        println!("START: {name}, control={control}, pid={}", std::process::id());
                        if control {
                            if !send(hwnd, message, value)
                                || !send(hwnd, WM_KILLFOCUS, 0)
                                || !send(hwnd, WM_NULL, 0)
                            {
                                fail("serial input/focus control timed out");
                            }
                            println!("PASS: serial {name}/focus, responsive UI");
                            continue;
                        }
                        SEND_FOCUS.store(false, Ordering::SeqCst);
                        FOCUS_QUEUED.store(false, Ordering::SeqCst);
                        FOCUS_DISPATCHED.store(false, Ordering::SeqCst);
                        OUTER_MESSAGE.store(message, Ordering::SeqCst);
                        ARMED.store(true, Ordering::SeqCst);
                        let focus = std::thread::spawn(move || {
                            let start = Instant::now();
                            while !SEND_FOCUS.load(Ordering::SeqCst) {
                                if start.elapsed() > Duration::from_secs(5) {
                                    fail("input hook was not reached");
                                }
                                std::thread::sleep(Duration::from_millis(1));
                            }
                            send(hwnd, WM_KILLFOCUS, 0)
                        });
                        if !send(hwnd, message, value) {
                            fail(&format!(
                                "input 0x{message:04x} timed out during focus reentry; queued={}, dispatched={}",
                                FOCUS_QUEUED.load(Ordering::SeqCst),
                                FOCUS_DISPATCHED.load(Ordering::SeqCst),
                            ));
                        }
                        if !focus.join().unwrap()
                            || !FOCUS_QUEUED.load(Ordering::SeqCst)
                            || !FOCUS_DISPATCHED.load(Ordering::SeqCst)
                        {
                            fail("sent focus callback did not complete");
                        }
                        if !send(hwnd, WM_NULL, 0) {
                            fail("UI message loop did not recover");
                        }
                        println!("PASS: input 0x{message:04x}, queued focus completed, responsive UI");
                    }
                    unsafe {
                        let _ = UnhookWindowsHookEx(
                            windows::Win32::UI::WindowsAndMessaging::HHOOK(hook_id as *mut _),
                        );
                    }
                    app.exit(0);
                });
                Ok(())
            })
            .run(context)
            .expect("run disposable native input regression");
    }
}
