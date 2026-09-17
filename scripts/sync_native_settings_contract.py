#!/usr/bin/env python3
"""Export the native settings allowlist and original Rust argument signatures.

Shared by SwiftUI and WinUI 3; CI --check detects contract/registration drift.
Payload objects retain the existing command DTOs; this is not a second schema.
"""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'contracts/native-settings/v1/commands.json'
ADAPTERS = {
    'native_settings_capabilities': ([], 'NativeSettingsCapabilities'),
    'native_download_update': ([], '()'),
    'native_terminal_snapshot': ([{'name': 'sessionId', 'rust_type': 'String', 'optional': False}], 'TerminalSnapshot'),
}

def export():
    source = (ROOT / 'crates/wisp-dto/src/native_settings.rs').read_text()
    block = source.split('pub const COMMANDS:')[1].split('];')[0]
    commands = re.findall(r'"([a-z_]+)"', block)
    if len(commands) != len(set(commands)):
        raise ValueError('Duplicate native settings command')
    handlers = (ROOT / 'src-tauri/src/lib.rs').read_text().split('.invoke_handler(')[-1]
    sources = [(p, p.read_text()) for p in (ROOT / 'src-tauri/src').rglob('*.rs')]
    exported = []
    for name in sorted(commands + ['native_settings_capabilities']):
        if name in ADAPTERS:
            args, result = ADAPTERS[name]
            location = 'src-tauri/src/native_settings.rs'
        else:
            if not re.search(r'\b' + name + r'\s*,', handlers):
                raise ValueError(f'{name} is not registered in Tauri')
            matches = [(p, re.search(r'\bfn\s+' + name + r'\s*\((.*?)\)\s*(?:->\s*(.*?))?\s*\{', text, re.S)) for p, text in sources]
            path, match = next((p, m) for p, m in matches if m)
            args = []
            for line in match[1].splitlines():
                m = re.match(r'\s*(?:mut\s+)?(\w+)\s*:\s*(.*?)\s*,?\s*$', line)
                if not m: continue
                key, typ = m.groups(); typ = typ.rstrip(',')
                if re.search(r'(?:State<|AppHandle|WorkspaceSurface|WebviewWindow)', typ): continue
                camel = re.sub(r'_([a-z])', lambda m: m[1].upper(), key)
                args.append({'name': camel, 'rust_type': typ, 'optional': typ.startswith('Option<')})
            result = match[2]
            location = str(path.relative_to(ROOT))
        exported.append({'command': name, 'arguments': args, 'result': result, 'source': location})
    return (json.dumps({'schema': 'wisp.native-settings.v1', 'commands': exported}, ensure_ascii=False, indent=2) + '\n').encode()

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--check', action='store_true'); args = parser.parse_args()
    expected = export()
    if args.check:
        if not TARGET.exists() or TARGET.read_bytes() != expected: parser.exit(1, 'Native settings contract drift. Run scripts/sync_native_settings_contract.py\n')
    else:
        TARGET.parent.mkdir(parents=True, exist_ok=True); TARGET.write_bytes(expected)

if __name__ == '__main__': main()
