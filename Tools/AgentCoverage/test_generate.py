"""Regression checks for inventory extraction and drift detection, not xEdit runtime."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("agent_coverage", Path(__file__).with_name("generate.py"))
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class CoverageTests(unittest.TestCase):
    def test_comments_do_not_create_operations_or_shift_source_locations(self):
        text = "// fake\n'// literal with ''quotes''' {comment\nblock}\n(* other *) live"
        code = audit.pascal_code(text)
        self.assertEqual(len(text), len(code))
        self.assertEqual([i for i, c in enumerate(text) if c == "\n"],
                         [i for i, c in enumerate(code) if c == "\n"])
        self.assertIn("'// literal with ''quotes'''", code)
        self.assertNotIn("fake", code)
        self.assertNotIn("block", code)
        self.assertTrue(code.endswith("live"))

    def test_nested_dfm_events_dynamic_bindings_and_native_guards(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "xEdit").mkdir()
            (root / "xEdit/xeMainForm.dfm").write_text(
                "object frmMain: TfrmMain\n  object menu: TMenuItem\n"
                "    Caption = 'Parent'\n    object child: TMenuItem\n"
                "      Caption = 'Child''s action'\n      OnClick = ChildClick\n"
                "    end\n    OnClick = ParentClick\n    OnKeyDown = ParentKey\n  end\nend\n")
            (root / "xEdit/xeMainForm.pas").write_text(
                "// item.OnClick := FakeClick;\nitem.OnClick := DynamicClick;\n"
                "item.OnClick := DynamicClick;\nitem.OnClick := nil;\n"
                "menu.Visible := wbIsSkyrim and wbEditAllowed;\n"
                "procedure TfrmMain.ParentClick(Sender: TObject);\nbegin end;\n")
            with patch.object(audit, "ROOT", root):
                rows = audit.extract_gui()
            self.assertEqual([r["handler"] for r in rows],
                             ["ChildClick", "ParentClick", "ParentKey", "DynamicClick"])
            self.assertEqual(rows[0]["caption"], "Child's action")
            self.assertEqual(rows[1]["component"], "menu")
            self.assertEqual(len({r["id"] for r in rows}), 4)
            self.assertEqual(rows[1]["nativeGuards"][0]["expression"], "wbIsSkyrim and wbEditAllowed")
            self.assertEqual(rows[1]["handlerSources"][0]["line"], 6)

    def test_registration_constants_resolve_and_comments_are_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "xEdit").mkdir()
            (root / "xEdit/xeAutomationCommandsFixture.pas").write_text(
                "const FixtureKind = 'fixture.job';\n"
                "{xeAutomationRegisterCommand('fake.command', Fake);}\n"
                "xeAutomationRegisterCommand('fixture.read', ReadHandler);\n"
                "xeAutomationRegisterJobKindWithValidator(FixtureKind, JobHandler, Validate);\n")
            with patch.object(audit, "ROOT", root):
                rows = audit.extract_commands()
            self.assertEqual([r["name"] for r in rows], ["fixture.read", "fixture.job"])
            self.assertEqual(rows[0]["source"]["line"], 3)
            self.assertEqual(rows[1]["kind"], "job")

    def test_inventory_order_is_identical_on_windows_and_linux(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "xEdit").mkdir()
            for name in ["xeaForm.dfm", "xeZForm.dfm"]:
                (root / "xEdit" / name).write_text(
                    "object form: TForm\n  OnClick = FormClick\nend\n")
            (root / "xEdit/xeMainForm.pas").write_text("unit xeMainForm;")
            with patch.object(audit, "ROOT", root):
                rows = audit.extract_gui()
            self.assertEqual([r["source"]["file"] for r in rows],
                             ["xEdit/xeZForm.dfm", "xEdit/xeaForm.dfm"])

    def test_ledger_count_change_fails_closed(self):
        text = ("xeScriptRuntimePolicyEntries: array[0..1] of Entry = (\n"
                "(Symbol: 'Read'; Action: aaGet; Policy: srpAllowPureRead; PathArgIndex: -1));")
        with patch.object(audit, "read", return_value=text):
            with self.assertRaisesRegex(ValueError, "format/count changed"):
                audit.extract_policy()

    def test_adapter_deny_precedence_and_unclassified_symbols(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "xEdit/JvI").mkdir(parents=True)
            (root / "xEdit/JvI/fixture.pas").write_text(
                "AddFunction(cUnit, 'Read', Handler, 0, [], varEmpty);\n"
                "AddGet(TWidget, 'Write', Handler, 0, [], varEmpty);\n"
                "AddSet(TWidget, 'Unknown', Handler, 0, [], varEmpty);\n")
            policy = [{"symbol": "Read", "action": "aaGet", "policy": "srpAllowPureRead"},
                      {"symbol": "TWidget.Write", "action": "aaGet", "policy": "srpAllowInMemoryMutate"},
                      {"symbol": "TWidget.Write", "action": "aaGet", "policy": "srpDenyWriteFs"}]
            with patch.object(audit, "ROOT", root):
                rows = audit.extract_adapters(policy)
            self.assertEqual([r["status"] for r in rows], ["allowed", "denied", "unclassified"])

    def test_unknown_route_and_missing_operation_metadata_are_rejected(self):
        config = {"profiles": {"example": {"routes": ["missing.operation"]}},
                  "handlers": {}, "components": {}, "forms": {}, "requiredProfiles": [], "gaps": [],
                  "commandFamilies": {"system": {}}, "operationOverrides": {}}
        registered = [{"name": "system.ping", "kind": "command"}]
        with patch.object(audit, "extract_commands", return_value=registered), \
             patch.object(audit, "extract_policy", return_value=[]), \
             patch.object(audit, "extract_gui", return_value=[]):
            with self.assertRaisesRegex(ValueError, "Unknown command/job"):
                audit.build(config)
            config["profiles"]["example"]["routes"] = []
            with self.assertRaisesRegex(ValueError, "explicit effect metadata"):
                audit.build(config)

    def test_check_detects_artifact_drift_and_unassessed_routes(self):
        data = {"registeredOperations": [], "guiActions": [], "scriptPolicy": []}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cfg = root / "routes.json"
            cfg.write_text("{}")
            with patch.object(audit, "ROOT", root), patch.object(audit, "CONFIG", cfg), \
                 patch.object(audit, "JSON_OUT", root / "coverage.json"), \
                 patch.object(audit, "MD_OUT", root / "matrix.md"), \
                 patch.object(audit, "build", return_value=data), \
                 patch.object(audit, "render", return_value="matrix\n"), \
                 contextlib.redirect_stdout(io.StringIO()):
                with patch("sys.argv", ["generate.py"]):
                    self.assertEqual(audit.main(), 0)
                with patch("sys.argv", ["generate.py", "--check"]):
                    self.assertEqual(audit.main(), 0)
                    (root / "matrix.md").write_text("stale")
                    self.assertEqual(audit.main(), 1)
                data["guiActions"] = [{"id": "new-operation", "status": "unassessed"}]
                with patch("sys.argv", ["generate.py"]):
                    self.assertEqual(audit.main(), 0)
                with patch("sys.argv", ["generate.py", "--check"]):
                    self.assertEqual(audit.main(), 1)


if __name__ == "__main__":
    unittest.main()
