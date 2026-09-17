"""Regression: filesystem traversal must not select a same-named Rust helper."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import sync_native_settings_contract as contract


class ExportTests(unittest.TestCase):
    def test_only_tauri_command_is_exported_with_portable_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "crates/wisp-dto/src/native_settings.rs"
            source.parent.mkdir(parents=True)
            source.write_text('pub const COMMANDS: &[&str] = &["example"];', encoding="utf-8")
            rust = root / "src-tauri/src"
            rust.mkdir(parents=True)
            (rust / "lib.rs").write_text('.invoke_handler(example,)', encoding="utf-8")
            (rust / "a_helper.rs").write_text('fn example(secret: &str) -> () {}', encoding="utf-8")
            (rust / "z_command.rs").write_text(
                '#[tauri::command]\npub(super) async fn example(\n project_id: String,\n) -> String { "研究" }',
                encoding="utf-8")
            with patch.object(contract, "ROOT", root):
                command = json.loads(contract.export())["commands"][0]
                self.assertEqual(command["source"], "src-tauri/src/z_command.rs")
                self.assertEqual(command["arguments"], [{"name": "projectId", "rust_type": "String", "optional": False}])
                (rust / "duplicate.rs").write_text('#[tauri::command]\nfn example() {}', encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "Expected one Tauri command"):
                    contract.export()


if __name__ == "__main__":
    unittest.main()
