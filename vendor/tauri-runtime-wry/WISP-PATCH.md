# Temporary Tao compatibility override

This directory contains the published `tauri-runtime-wry 2.11.4` crate, under
its original MIT / Apache-2.0 licenses. It is excluded from Wisp's workspace
members and selected through the root `[patch.crates-io]` section.

## Provenance

- Registry: <https://crates.io/crates/tauri-runtime-wry/2.11.4>
- Published `.crate` SHA-256:
  `4e6fac707727b7a2f48e4ded90976324267371073edbb415ffb73bb0458d203f`
- Upstream revision recorded by the published crate:
  `ca90b46b2e2cbbc981dae1b809f4af4343fe0558`
- Upstream path: `crates/tauri-runtime-wry`
- `src/`, `build.rs`, `README.md`, `Cargo.toml.orig`, and both license files are
  unchanged. Registry cache markers and the crate's own lockfile are omitted;
  Wisp's root lockfile controls the build.

## Local change

Only the normalized, active `Cargo.toml` is changed:

```diff
 [dependencies.tao]
-version = "0.35.0"
+version = "0.37.0"
```

`Cargo.toml.orig` is retained as unmodified provenance, not as the build manifest.
No runtime Rust code is changed. Wisp continues to lock Tauri 2.11.3,
tauri-runtime 2.11.3, and Wry 0.55.1. Tao 0.37.0 includes
[tao#1215](https://github.com/tauri-apps/tao/pull/1215), which avoids holding
keyboard/IME locks across reentrant Win32 `PeekMessageW` calls.

This fixes the reproduced Windows deadlock tracked in
[Wisp #1265](https://github.com/xuzhougeng/wisp-science/issues/1265).
The separate macOS modal-sheet/redraw deadlock in
[Wisp #1250](https://github.com/xuzhougeng/wisp-science/issues/1250) is
handled by the vendored Tao patch in `vendor/tao`.

## Removal

When a published `tauri-runtime-wry` supports Tao 0.37 or a later version with
the fix, remove this directory, the root patch, and the workspace exclusion.
Update the compatible Tauri/runtime lockfile entries together and rerun the
native input regression, real WebView smokes, and platform checks documented in
`docs/windows-input-reentrancy-reproduction.md` and
`docs/tao-upgrade-assessment.md`. Keep the regression after removing the override.
