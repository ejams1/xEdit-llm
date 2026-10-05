"""ESL apply fixture/assertion integrity; no native execution."""
from copy import deepcopy
import struct
import unittest

import esl_apply_step_fixture as fixture


def snapshot(state="running", remaps=1, flag="not_started", dry=False):
    done = state == "succeeded"
    row = {"fileName": fixture.compact.TARGET, "complete": done, "analysisComplete": True,
           "planningComplete": True, "preflightComplete": True, "requiresCompact": True,
           "remapCount": 2, "appliedRemaps": remaps, "flagOutcome": flag,
           "eslFlagChanged": flag in ("applied", "planned"), "plannedRemaps": 2 if dry else 0,
           "mutationState": {"mutationsObserved": not dry and bool(remaps)}}
    return {"state": state, "dryRun": dry, "terminal": state != "running",
            "cursorRetained": state == "running", "findingsComplete": done,
            "summary": {"remapsApplied": remaps, "remapsPlanned": 2 if dry else 0,
                        "applied": int(flag == "applied"), "changed": not dry and bool(remaps)},
            "result": {"files": [row]}, "progress": {"completed": int(done), "total": 1,
                "remaining": int(not done), "detail": {"workLimit": 128, "softBudgetMs": 20,
                    "mutationLimit": 1, "nativeCallsPreemptible": False, "cursor": {
                        "lastWorkUnits": 128, "workLimit": 128, "retainedDepth": 0,
                        "depthLimit": 64, "totalWorkUnits": 6000, "totalWorkLimit": 1000000}}}}


class EslApplyStepTests(unittest.TestCase):
    def test_fixture_owned_capacity_and_eligible_in_range_record(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            rows, _ = fixture.compact.raw_headers(blob)
            self.assertEqual(len(rows) - 1, struct.unpack_from("<I", blob, 34)[0], name)
            self.assertEqual(len(rows), len(set(rows)), name)
        rows, _ = fixture.compact.raw_headers(data[fixture.TOO_MANY])
        self.assertEqual(len(rows) - 1, 4100)
        self.assertGreater(len(rows) - 1, 4095)
        self.assertIn((b"KYWD", 0x01000800), fixture.compact.raw_headers(data[fixture.ELIGIBLE])[0])

    def test_native_object_id_masks_full_and_distinct_light_slots(self):
        self.assertEqual(fixture.object_id({"formId": "02000801"}), 0x801)
        self.assertEqual(fixture.object_id({"formId": "FE 123 801"}), 0x801)
        self.assertEqual(fixture.object_id({"formId": "FE456801"}), 0x801)
        self.assertEqual(fixture.object_id({"formId": "02010000"}), 0x10000)

    def test_accepts_partial_remaps_before_flag_and_dry_projected_flag(self):
        for state in ("running", "canceled", "failed"):
            fixture.validate_state(snapshot(state))
            fixture.validate_state(snapshot(state, 2))
        fixture.validate_state(snapshot("succeeded", 2, "applied"))
        fixture.validate_state(snapshot("succeeded", 0, "planned", True))

    def test_refuses_early_flag_and_false_completion_counters(self):
        for mutate in (
            lambda s: s["result"]["files"][0].update(analysisComplete=False),
            lambda s: s["result"]["files"][0].update(preflightComplete=False),
            lambda s: s["result"]["files"][0].update(appliedRemaps=1),
            lambda s: s["result"]["files"][0].update(flagOutcome="not_started"),
            lambda s: s["summary"].update(applied=0),
            lambda s: s["progress"]["detail"]["cursor"].update(lastWorkUnits=129),
            lambda s: s.update(cursorRetained=True),
        ):
            state = deepcopy(snapshot("succeeded", 2, "applied"))
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)


if __name__ == "__main__":
    unittest.main()
