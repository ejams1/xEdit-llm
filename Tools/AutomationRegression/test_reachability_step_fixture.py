"""Fixture/acceptance assertions, not native reachability execution."""
from copy import deepcopy
import struct
import unittest

import reachability_step_fixture as fixture
from hygiene_step_fixture import raw_headers


def snapshot(state="running"):
    done = state == "succeeded"
    return {"state": state, "terminal": state != "running", "cursorRetained": state == "running",
            "findingsComplete": done, "progress": {"completed": int(done), "total": 1,
            "remaining": int(not done), "detail": {"processed": 700 if done else 128, "total": 700,
            "lastWorkUnits": 128, "workLimit": 128, "remainingNativeVisitBudget": 4999000,
            "nativeCallsPreemptible": False, "softBudgetMs": 20, "stageComplete": done}}}


def classifications(explicit=False):
    rows = []
    names = ["ReachA", "ReachB", "IsolatedC", "IsolatedD", "ReachRoot"]
    names += [f"ReachStepUnused{i:04d}" for i in range(fixture.FILLERS)]
    for name in names:
        reached = name in {"ReachA", "ReachB", "ReachRoot"} or (explicit and name in {
            "IsolatedC", "IsolatedD", "ReachStepUnused0000", "ReachStepUnused0001"})
        rows.append({"editorId": name, "reachable": reached, "notReachable": not reached,
                     "validity": "historical classification only if containing job succeeds"})
    return rows


class ReachabilityStepTests(unittest.TestCase):
    def test_large_report_fixture_has_valid_counts_unique_ids_and_native_cycle_links(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            rows, groups = raw_headers(blob)
            self.assertEqual(len(rows) - 1, struct.unpack_from("<I", blob, 34)[0], name)
            self.assertEqual(len(rows), len(set(rows)), name)
        self.assertGreater(fixture.FILLERS + 4, 128)
        self.assertLess(fixture.FILLERS + 5, 1000)
        for identity in (0x01000800, 0x01000801, 0x01000802, 0x01000803):
            self.assertIn(b"LNAM\x04\0" + struct.pack("<I", identity), data[fixture.BASE])
        self.assertEqual(data[fixture.BASE].count(b"LNAM"), 4)

    def test_accepts_partial_canceled_failed_and_finished_states(self):
        for state in ("running", "canceled", "failed", "succeeded"):
            fixture.validate_state(snapshot(state))

    def test_rejects_capacity_completion_and_native_budget_lies(self):
        for mutate in (lambda s: s["progress"]["detail"].update(lastWorkUnits=129),
                       lambda s: s["progress"]["detail"].update(processed=701),
                       lambda s: s["progress"]["detail"].update(remainingNativeVisitBudget=0),
                       lambda s: s["progress"]["detail"].update(stageComplete=False),
                       lambda s: s.update(cursorRetained=True)):
            state = deepcopy(snapshot("succeeded"))
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)

    def test_exact_cycle_filler_classifications_and_historical_validity(self):
        for explicit in (True, False):
            rows = classifications(explicit)
            fixture.assert_classifications(rows, explicit)
            wrong = deepcopy(rows)
            wrong[2]["reachable"] = not explicit
            with self.assertRaises(AssertionError):
                fixture.assert_classifications(wrong, explicit)
            with self.assertRaises(AssertionError):
                fixture.assert_classifications(rows[:-1], explicit)
            wrong = deepcopy(rows)
            wrong[0]["validity"] = "complete"
            with self.assertRaises(AssertionError):
                fixture.assert_classifications(wrong, explicit)


if __name__ == "__main__":
    unittest.main()
