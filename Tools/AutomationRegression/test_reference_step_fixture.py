"""Binary scene and acceptance assertions; does not execute native indexing."""
from copy import deepcopy
import struct
import unittest

import reference_step_fixture as fixture
from hygiene_step_fixture import raw_headers
from row_fixture import disk_state


def snapshot(state="running", complete=False):
    return {"state": state, "terminal": state != "running", "cursorRetained": state == "running",
            "findingsComplete": state == "succeeded", "summary": {"indexedFiles": int(complete)},
            "result": {"steps": [{"phase": "references", "complete": complete,
                       "currentAfter": complete, "outcome": "completed" if complete else "in_progress"}]},
            "progress": {"total": 2, "completed": int(complete), "remaining": 2 - int(complete),
                         "detail": {"lastWorkUnits": 128, "workLimit": 128, "softBudgetMs": 20,
                         "scanWorkUnits": 256, "scanWorkLimit": 1000000, "nativeUnits": 100,
                         "retainedDepth": 0 if complete else 2, "depthLimit": 128,
                         "nativeCallsPreemptible": False}}}


class ReferenceStepTests(unittest.TestCase):
    def test_scene_counts_ids_links_and_empty_native_owner_group(self):
        for name, blob in fixture.fixtures().items():
            rows, _ = raw_headers(blob)
            self.assertEqual(len(rows) - 1, struct.unpack_from("<I", blob, 34)[0], name)
            self.assertEqual(len(rows), len(set(rows)), name)
            masters, payloads = disk_state(blob)
            self.assertEqual(masters, ["Fallout4.esm"])
            callers = [row for name, row in payloads.items() if name.startswith("ReferenceCaller")]
            self.assertEqual(len(callers), fixture.COUNT)
            self.assertTrue(all(row["fields"][b"LNAM"] == [struct.pack("<I", 0x01000800)] for row in callers))
            empty_group = struct.pack("<4sIIIHHHH", b"GRUP", 24, 0x01003000, 9, 0, 0, 0, 0)
            owner_group = struct.pack("<4sIIIHHHH", b"GRUP", 48, 0x01003000, 6, 0, 0, 0, 0)
            self.assertIn(owner_group + empty_group, blob)
            self.assertGreater(fixture.COUNT, 128)

    def test_accepts_partial_terminal_and_completed_prefix(self):
        for state in ("running", "canceled", "failed"):
            for complete in (False, True):
                fixture.validate_state(snapshot(state, complete))

    def test_rejects_partial_current_index_and_false_counts_bounds_retention(self):
        for mutate in (
            lambda s: s["result"]["steps"][0].update(currentAfter=True),
            lambda s: s["summary"].update(indexedFiles=1),
            lambda s: s["progress"]["detail"].update(lastWorkUnits=129),
            lambda s: s["progress"]["detail"].update(scanWorkUnits=1000001),
            lambda s: s["progress"]["detail"].update(nativeUnits=257),
            lambda s: s["progress"]["detail"].update(retainedDepth=129),
            lambda s: s.update(cursorRetained=True),
        ):
            value = deepcopy(snapshot("canceled"))
            mutate(value)
            with self.assertRaises(AssertionError):
                fixture.validate_state(value)


if __name__ == "__main__":
    unittest.main()
