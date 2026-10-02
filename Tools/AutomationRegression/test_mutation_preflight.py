"""Safety structure checks; native failure-path acceptance remains pending."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MutationPreflightTests(unittest.TestCase):
    def test_editor_id_support_is_checked_before_native_add(self):
        source = (ROOT / "xEdit/xeAutomationCommandsRecords.pas").read_text()
        body = source.split("function xeAutomationRecordsCreate(", 1)[1].split("function xeAutomationRecordsDelete(", 1)[0]
        self.assertLess(body.index("ContainsKnownSubRecord[ksrEditorID]"), body.index("lFile.Add("))

    def test_generic_job_errors_no_longer_claim_nonpartial_execution(self):
        source = (ROOT / "xEdit/xeAutomationJobs.pas").read_text()
        body = source.split("procedure xeAutomationAdvanceJob(", 1)[1].split("function xeAutomationStartJob(", 1)[0]
        self.assertNotIn("FailureData.B['partial'] := False", body)
        self.assertIn("FailureData['partial'] := nil", body)


if __name__ == "__main__":
    unittest.main()
