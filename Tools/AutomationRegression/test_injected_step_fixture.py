"""Binary injected scene and cancellation assertion integrity, not native tests."""
from copy import deepcopy
import struct
import unittest

import injected_step_fixture as fixture
from hygiene_step_fixture import raw_headers
from row_fixture import disk_state


def snapshot(state="running", complete=False):
    row = {"source": {"file": fixture.BASE, "formId": "01001000"},
           "preserved": {"file": fixture.PROVIDER, "formId": "01001000"},
           "preservationComplete": True, "complete": complete, "cleaned": complete,
           "outcome": "applied" if complete else "preserved", "requiresManualReview": False}
    return {"state": state, "terminal": state != "running", "cursorRetained": state == "running",
            "findingsComplete": state == "succeeded", "dryRun": False,
            "summary": {"planned": 1, "applied": int(complete), "requiresManualReview": 0},
            "result": {"files": [{"complete": False}], "preflight": {"complete": True},
                       "plan": [{"file": fixture.BASE}], "records": [row]},
            "progress": {"total": 2, "completed": 0, "remaining": 2, "detail": {
                "nativeUnitLimit": 1, "nativeCallsPreemptible": False, "loadedFilesProcessed": 5,
                "loadedFilesTotal": 5, "loadedFileLimit": 256, "globalRecordsPlanned": 1,
                "globalPreflightComplete": True, "planCount": 1, "recordLimit": 128, "planByteLimit": 524288}}}


class InjectedStepTests(unittest.TestCase):
    def test_raw_scene_counts_unique_ids_and_distinct_source_ownership(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            rows, _ = raw_headers(blob)
            self.assertEqual(len(rows) - 1, struct.unpack_from("<I", blob, 34)[0], name)
            self.assertEqual(len(rows), len(set(rows)), name)
        base, _ = raw_headers(data[fixture.BASE])
        second, _ = raw_headers(data[fixture.SECOND])
        self.assertTrue(all(identity >> 24 == 1 for sig, identity in base if sig != b"TES4"))
        self.assertTrue(all(identity >> 24 == 2 for sig, identity in second if sig != b"TES4"))
        self.assertEqual(len(base) + len(second) - 4, fixture.COUNT)

    def test_missing_source_injection_ids_and_complete_unrelated_payloads(self):
        data = fixture.fixtures()
        _, base = disk_state(data[fixture.BASE])
        _, second = disk_state(data[fixture.SECOND])
        _, provider = disk_state(data[fixture.PROVIDER])
        self.assertEqual(provider["InjectedStepPayload"]["identity"], 0x2000)
        self.assertNotIn(0x2000, {row["identity"] for row in base.values()})
        for name, row in {**base, **second}.items():
            if name.startswith("InjectedStepRoot"):
                self.assertEqual([struct.unpack_from("<I", v, 4)[0] for v in row["fields"][b"LVLO"]],
                                 [0x01002000, 0x01000801])
        self.assertEqual([struct.unpack_from("<I", v, 4)[0] for v in base["InjectedStepOtherProvider"]["fields"][b"LVLO"]],
                         [0x01003000, 0x01000801])

    def test_accepts_copied_only_and_completed_record_in_partial_job(self):
        for state in ("running", "canceled", "failed"):
            fixture.validate_state(snapshot(state))
            fixture.validate_state(snapshot(state, True))

    def test_refuses_cleanup_without_preservation_or_global_preflight(self):
        for mutate in (
            lambda s: s["result"]["records"][0].update(preservationComplete=False),
            lambda s: s["result"]["preflight"].update(complete=False),
            lambda s: s["progress"]["detail"].update(globalPreflightComplete=False),
            lambda s: s["summary"].update(applied=0),
            lambda s: s["progress"]["detail"].update(planCount=129),
            lambda s: s["progress"]["detail"].update(loadedFilesTotal=257),
            lambda s: s.update(cursorRetained=True),
        ):
            value = deepcopy(snapshot("canceled", True))
            mutate(value)
            with self.assertRaises(AssertionError):
                fixture.validate_state(value)


if __name__ == "__main__":
    unittest.main()
