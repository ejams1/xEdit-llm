"""ESL fixture integrity and acceptance assertions; no native execution."""
from copy import deepcopy
import struct
import unittest

import esl_step_fixture as fixture
from row_fixture import disk_state


def snapshot(state="running"):
    complete = state == "succeeded"
    row = {"fileName": fixture.PATCH, "complete": complete, "statsComplete": complete,
           "newRecordCount": 1, "minObjectId": "00000A00", "maxObjectId": "00000A00"}
    if complete:
        row.update(eligible=True, requiresCompact=False)
    return {"state": state, "terminal": state != "running", "cursorRetained": state == "running",
            "findingsComplete": complete, "summary": {"eligible": int(complete), "ineligible": 0,
                                                       "changed": False, "requiresSave": False},
            "result": {"files": [row]}, "progress": {
                "completed": int(complete), "total": 1, "remaining": int(not complete), "detail": {
                    "lastWorkUnits": 128, "workLimit": 128, "totalWorkUnits": 6000,
                    "totalWorkLimit": 1000000, "retainedDepth": 0 if complete else 3,
                    "depthLimit": 64, "newRecordCount": 1, "seenRecordLimit": 100000,
                    "objectIdProbes": 100, "objectIdProbeLimit": 2560,
                    "softBudgetMs": 20, "nativeCallsPreemptible": False}}}


class EslStepTests(unittest.TestCase):
    def test_fixture_counts_unique_ids_and_next_id_hints(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            rows, groups = fixture.raw_headers(blob)
            self.assertEqual(len(rows) - 1, struct.unpack_from("<I", blob, 34)[0], name)
            self.assertEqual(len(rows), len(set(rows)), name)
        self.assertGreater(fixture.COUNT, 4095)
        names, rows = disk_state(data[fixture.PATCH])
        self.assertEqual(names, ["Fallout4.esm", fixture.BASE])
        self.assertEqual(len(rows), fixture.COUNT + 1)
        self.assertEqual(sum(identity >> 24 == 2 for sig, identity in fixture.raw_headers(data[fixture.PATCH])[0]), 1)
        self.assertIn((b"KYWD", 0x01010000), fixture.raw_headers(data[fixture.HIGH])[0])
        self.assertIn((b"KYWD", 0x0100FF00), fixture.raw_headers(data[fixture.SPARSE])[0])
        self.assertEqual(fixture.raw_headers(data[fixture.FRESH])[0], [(b"TES4", 0)])

    def test_new_cell_has_valid_decimal_groups_and_distinct_ownership(self):
        rows, groups = fixture.raw_headers(fixture.fixtures()[fixture.CELL])
        self.assertIn((b"CELL", 0x02006000), rows)
        self.assertIn((2, 6), groups)
        self.assertIn((3, 7), groups)

    def test_accepts_partial_cancel_failed_and_finished_statistics(self):
        for state in ("running", "canceled", "failed", "succeeded"):
            fixture.validate_state(snapshot(state))

    def test_refuses_unsupported_completion_counts_capacity_and_mutation_claims(self):
        for mutate in (
            lambda s: s["progress"]["detail"].update(lastWorkUnits=129),
            lambda s: s["progress"]["detail"].update(objectIdProbes=2561),
            lambda s: s["progress"]["detail"].update(retainedDepth=65),
            lambda s: s["progress"]["detail"].update(newRecordCount=100001),
            lambda s: s["progress"]["detail"].update(totalWorkUnits=1000001),
            lambda s: s["summary"].update(changed=True),
            lambda s: s["summary"].update(eligible=2),
            lambda s: s.update(cursorRetained=True),
        ):
            state = deepcopy(snapshot("succeeded"))
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)
        partial = snapshot()
        partial["result"]["files"][0]["eligible"] = True
        with self.assertRaises(AssertionError):
            fixture.validate_state(partial)


if __name__ == "__main__":
    unittest.main()
