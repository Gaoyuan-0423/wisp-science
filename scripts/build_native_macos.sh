#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'The SwiftUI preview must be built on macOS.' >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/target/native-macos"
APP="$BUILD/Wisp Science Preview.app"
export CLANG_MODULE_CACHE_PATH="$BUILD/clang-module-cache"

python3 "$ROOT/scripts/sync_native_design.py" --check
cargo build --manifest-path "$ROOT/Cargo.toml" --target-dir "$ROOT/target" --locked -p wisp-service
# A small inert document hosts legacy command extractors. No WebView settings
# UI is bundled in this helper; all visible settings controls are native.
HOST_ASSETS="$BUILD/host-assets"
mkdir -p "$HOST_ASSETS"
cp "$ROOT/ui/native-host.html" "$HOST_ASSETS/native-host.html"
cp "$ROOT/ui/native-host.html" "$HOST_ASSETS/index.html"
TAURI_CONFIG="$(python3 -c 'import json,sys; print(json.dumps({"build":{"frontendDist":sys.argv[1]}}))' "$HOST_ASSETS")" \
  cargo build --manifest-path "$ROOT/Cargo.toml" --target-dir "$ROOT/target" --locked -p wisp-tauri --features custom-protocol
swift build --package-path "$ROOT/apps/macos" --scratch-path "$BUILD/swift" --disable-sandbox
SWIFT_BIN="$(swift build --package-path "$ROOT/apps/macos" --scratch-path "$BUILD/swift" --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$SWIFT_BIN/WispSciencePreview" "$APP/Contents/MacOS/WispSciencePreview"
install -m 755 "$ROOT/target/debug/wisp-service" "$APP/Contents/MacOS/wisp-service"
cp "$ROOT/src-tauri/icons/icon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SWIFT_BIN/WispSciencePreview_WispProjectBrowserUI.bundle" "$APP/Contents/Resources/"
cp -R "$SWIFT_BIN/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
# SwiftTerm 1.19 probes Contents/Resources itself. A resource symlink at the
# .app root makes codesign reject the bundle as unsealed; remove the legacy
# link left by earlier native preview builds.
if [[ -L "$APP/SwiftTerm_SwiftTerm.bundle" ]]; then
  rm "$APP/SwiftTerm_SwiftTerm.bundle"
fi
HOST_APP="$APP/Contents/Helpers/Wisp Desktop Host.app"
mkdir -p "$HOST_APP/Contents/MacOS" "$HOST_APP/Contents/Resources"
install -m 755 "$ROOT/target/debug/wisp-tauri" "$HOST_APP/Contents/MacOS/wisp-tauri"
for resource in skills python r browser-extension seed; do
  rm -rf "$HOST_APP/Contents/Resources/$resource"
  cp -R "$ROOT/$resource" "$HOST_APP/Contents/Resources/$resource"
done
cp "$ROOT/apps/macos/HostInfo.plist" "$HOST_APP/Contents/Info.plist"
python3 - "$ROOT/src-tauri/tauri.conf.json" "$HOST_APP/Contents/Info.plist" <<'PY_VERSION'
import json, plistlib, sys
with open(sys.argv[1]) as config:
    version = json.load(config)["version"]
with open(sys.argv[2], "rb") as source:
    info = plistlib.load(source)
info["CFBundleShortVersionString"] = version
with open(sys.argv[2], "wb") as target:
    plistlib.dump(info, target)
PY_VERSION
cp "$ROOT/apps/macos/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\nOpen with: open "%s"\n' "$APP" "$APP"
