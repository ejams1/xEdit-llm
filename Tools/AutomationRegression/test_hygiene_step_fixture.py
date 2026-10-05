"""Fixture byte integrity and acceptance assertions; no native execution."""
from copy import deepcopy
import struct
import unittest

import hygiene_step_fixture as fixture
from row_fixture import disk_state


def snapshot(state="running", dry=False):
    complete = state == "succeeded"
    operation = {"operation": "clean_masters", "complete": complete,
                 "outcome": ("planned" if dry else "applied") if complete else "pending"}
    row = {"fileName": fixture.STEPPED, "complete": complete, "operations": [operation],
           "mutationState": {"mutationsObserved": complete and not dry}}
    field = "planned" if dry else "applied"
    row[field] = int(complete)
    return {"state": state, "dryRun": dry, "terminal": state != "running",
            "findingsComplete": complete, "cursorRetained": state == "running",
            "summary": {field: int(complete)}, "result": {"files": [row]},
            "progress": {"completed": int(complete), "total": 1, "remaining": int(not complete),
                         "detail": {"lastWorkUnits": 128, "workLimit": 128,
                                    "lastMutations": int(complete and not dry), "mutationLimit": 1,
                                    "scanWorkUnits": 2208, "scanWorkLimit": 1000000,
                                    "retainedDepth": 0 if complete else 2, "depthLimit": 128,
                                    "nativeCallsPreemptible": False, "softBudgetMs": 20}}}


class HygieneStepTests(unittest.TestCase):
    def test_large_fixture_has_valid_counts_unique_full_ids_and_local_rebase_sentinel(self):
        for name, blob in fixture.fixtures().items():
            headers, groups = fixture.raw_headers(blob)
            self.assertEqual(len(headers) - 1, struct.unpack_from("<I", blob, 34)[0], name)
            self.assertEqual(len(headers), len(set(headers)), name)
            self.assertGreater(struct.unpack_from("<I", blob, 38)[0],
                               max(identity & 0xFFFFFF for _, identity in headers), name)
        blob = fixture.fixtures()[fixture.STEPPED]
        names, rows = disk_state(blob)
        self.assertEqual(names, fixture.INITIAL)
        self.assertEqual(len(rows), fixture.COUNT + 1)
        self.assertIn((b"FLST", 0x04006000), fixture.raw_headers(blob)[0])
        self.assertEqual(rows["HygieneOwnList"]["fields"][b"LNAM"],
                         [struct.pack("<I", 0x01000800), struct.pack("<I", 0x01001097)])

    def test_label_only_dependency_empty_groups_and_decimal_cell_placement(self):
        data = fixture.fixtures()
        for name in (fixture.STEPPED, fixture.DIRECT, fixture.CANCELED):
            headers, groups = fixture.raw_headers(data[name])
            self.assertFalse(any(identity >> 24 == 2 for _, identity in headers))
            self.assertIn((2, 2), groups)
            self.assertIn((3, 7), groups)
            self.assertIn((6, 0x02007000), groups)
            self.assertIn((9, 0x02007000), groups)
        self.assertEqual(fixture.raw_headers(data[fixture.LABEL])[0][-1], (b"CELL", 0x01007000))
        self.assertEqual(fixture.raw_headers(data[fixture.UNUSED])[0], [(b"TES4", 0)])
        self.assertEqual(data[fixture.STEPPED], data[fixture.DIRECT])

    def test_state_validation_accepts_partial_cancel_and_complete_dry_apply(self):
        for state in ("running", "canceled", "failed", "succeeded"):
            for dry in (True, False):
                fixture.validate_state(snapshot(state, dry))

    def test_state_validation_rejects_counter_and_completion_lies(self):
        for edit in (
            lambda s: s["progress"]["detail"].update(lastWorkUnits=129),
            lambda s: s["progress"]["detail"].update(lastMutations=2),
            lambda s: s["progress"]["detail"].update(retainedDepth=129),
            lambda s: s["progress"]["detail"].update(scanWorkUnits=1000001),
            lambda s: s["progress"]["detail"].update(nativeCallsPreemptible=True),
            lambda s: s.update(cursorRetained=True),
            lambda s: s["summary"].update(applied=2),
            lambda s: s["result"]["files"][0]["operations"][0].update(complete=False),
        ):
            state = deepcopy(snapshot("succeeded"))
            edit(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)

    def test_raw_decoder_refuses_record_or_group_extent_corruption(self):
        blob = fixture.fixtures()[fixture.STEPPED]
        with self.assertRaises((AssertionError, struct.error)):
            fixture.raw_headers(blob[:-1])


if __name__ == "__main__":
    unittest.main()
