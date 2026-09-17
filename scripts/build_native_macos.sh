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

cargo build --manifest-path "$ROOT/Cargo.toml" --target-dir "$ROOT/target" --locked -p wisp-service
swift build --package-path "$ROOT/apps/macos" --scratch-path "$BUILD/swift" --disable-sandbox
SWIFT_BIN="$(swift build --package-path "$ROOT/apps/macos" --scratch-path "$BUILD/swift" --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$SWIFT_BIN/WispSciencePreview" "$APP/Contents/MacOS/WispSciencePreview"
install -m 755 "$ROOT/target/debug/wisp-service" "$APP/Contents/MacOS/wisp-service"
cp "$ROOT/src-tauri/icons/icon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/apps/macos/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
printf 'Built: %s\nOpen with: open "%s"\n' "$APP" "$APP"
