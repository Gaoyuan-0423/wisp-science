#!/usr/bin/env python3
"""Export the WebView's brand, compose_icon glyphs and colors for native UI.

No rasterizer or third-party dependencies. Run --check in CI to detect drift.
WinUI can use the same SVGs and semantic color JSON when its view is added.
"""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "apps/macos/Sources/WispProjectBrowserUI/Resources"
ICONS = ("search", "refresh", "database", "folder", "star", "star-filled", "chat", "doc", "sync", "clock", "arrow-left", "chevron-left", "chevron-right", "gear", "calendar", "upload", "plus", "folder-plus", "research-trail", "book", "grid", "list", "share", "timeline", "archive", "bell", "attach", "terminal", "panel", "adjustments")
COLORS = ("bg-app", "bg-elev", "bg-sunken", "surface-hover", "text", "text-muted", "text-faint", "border", "border-strong", "clay", "clay-strong")


def exports():
    for theme in ("light", "dark"):
        yield f"wordmark-{theme}.svg", (ROOT / f"docs/assets/wordmark-{theme}.svg").read_bytes()
    source = (ROOT / "ui/src/app_support/messages.rs").read_text()
    for icon in ICONS:
        match = re.search(r'"' + re.escape(icon) + r'" => view! \{ (.*?) \}\.into_view\(\)', source)
        if not match:
            raise ValueError(f"Missing compose_icon: {icon}")
        body = match[1].replace("currentColor", "#000000")
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{body}</svg>\n'
        yield f"icon-{icon}.svg", svg.encode()
    css = (ROOT / "ui/src/styles/base.css").read_text()
    palettes = {}
    for theme, selector in (("light", ":root"), ("dark", ':root[data-theme="dark"]')):
        block = re.search(re.escape(selector) + r"\s*\{(.*?)\n\}", css, re.S)[1]
        values = dict(re.findall(r"--([\w-]+):\s*([^;]+);", block))
        palettes[theme] = {key: values[key] for key in COLORS}
    yield "palette.json", (json.dumps(palettes, indent=2) + "\n").encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for name, contents in exports():
        path = DEST / name
        if args.check:
            if not path.exists() or path.read_bytes() != contents:
                stale.append(name)
        else:
            DEST.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
    if stale:
        parser.exit(1, "Native assets differ from WebView: " + ", ".join(stale) + "\nRun python3 scripts/sync_native_design.py\n")


if __name__ == "__main__":
    main()
