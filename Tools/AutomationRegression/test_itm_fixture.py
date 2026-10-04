"""Fixture integrity and source safety checks; these are not game-backed evidence."""

from pathlib import Path
import unittest

import itm_fixture

ROOT = Path(__file__).resolve().parents[2]


class ItmFixtureTests(unittest.TestCase):
    def test_fixture_contains_identical_flag_only_and_payload_overrides(self):
        data = itm_fixture.fixtures()
        master = itm_fixture.read_keywords(data[itm_fixture.MASTER])
        override = itm_fixture.read_keywords(data[itm_fixture.PLUGIN])
        self.assertEqual(len(master), 5)
        self.assertEqual(len(override), 5)
        for name, flags, changed in itm_fixture.CASES:
            target_name = name + ("Edited" if changed else "")
            self.assertEqual(master[name][0], override[target_name][0])
            self.assertEqual(master[name][1], 0)
            self.assertEqual(override[target_name][1], flags)
            if flags:
                self.assertIn(name, master)
                self.assertIn(name, override)

    def test_validation_and_cleaning_share_comparison_without_conflict_bypass(self):
        validation = (ROOT / "xEdit/xeAutomationCommandsValidation.pas").read_text()
        cleaning = (ROOT / "xEdit/xeMainForm.pas").read_text()
        for text in (validation, cleaning):
            self.assertIn("if xeAutomationRecordIsIdenticalToMaster(lRecord) then", text)
            self.assertNotIn("xeAutomationElementContentEquals", text)
        check = validation.split("procedure TxeAutomationValidationStepper.CheckElement(")[1].split(
            "procedure TxeAutomationValidationStepper.AddNoFindings", 1)[0]
        self.assertNotIn("ConflictThis", check)


if __name__ == "__main__":
    unittest.main()
