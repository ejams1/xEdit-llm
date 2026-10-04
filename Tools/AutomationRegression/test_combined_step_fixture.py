"""Fixture integrity and acceptance assertion tests, not native xEdit execution."""
from copy import deepcopy
import struct
import unittest

from itm_fixture import read_keywords
from report_fixture import signatures
import combined_step_fixture as fixture


def snapshot(state="running", dry=False, masters=False):
    succeeded = state == "succeeded"
    applied = 0 if dry else 1
    row = {"operation": "sort_and_clean_masters" if masters else "remove_itm",
           "planned": 2 if masters else 1, "applied": applied, "skipped": 0,
           "complete": succeeded, "workComplete": succeeded,
           "mutationState": {"mutationsObserved": not dry}}
    if masters:
        row["operations"] = {
            "sort": {"planned": 1, "applied": applied, "skipped": 0, "complete": True},
            "cleanMasters": {"planned": 1, "applied": 0, "skipped": 0, "complete": succeeded}}
    return {"state": state, "dryRun": dry, "terminal": state != "running",
            "cursorRetained": state == "running", "findingsComplete": succeeded,
            "summary": {field: row[field] for field in ("planned", "applied", "skipped")},
            "result": {"files": [row]}, "progress": {
                "completed": int(succeeded), "total": 1, "remaining": int(not succeeded),
                "detail": {"lastWorkUnits": 16, "workLimit": 128,
                           "lastMutations": 0 if dry else 1, "mutationLimit": 16,
                           "nativeCallsPreemptible": False, "softBudgetMs": 20,
                           "collectedRecords": 0 if masters else 2004,
                           "processedRecords": 0 if masters else (2004 if succeeded else 16),
                           "retainedRecords": 0 if masters or succeeded else 1988}}}


class CombinedStepFixtureTests(unittest.TestCase):
    def test_full_file_exceeds_selective_scope_without_identity_collisions(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            roots = signatures(blob, 24)
            self.assertEqual(struct.unpack_from("<I", blob, 34)[0], len(roots) - 1, name)
            self.assertEqual(len({identity for _, identity, _ in roots}), len(roots), name)
        self.assertGreater(len(signatures(data[fixture.QUICK], 24)), 1000)
        base, override = map(read_keywords, (data[fixture.MASTER], data[fixture.QUICK]))
        self.assertEqual(len(base), fixture.KEYWORDS)
        self.assertEqual(set(base), set(override))
        for name, (identity, flags) in override.items():
            self.assertEqual(base[name], (identity, 0))
            self.assertEqual(flags, 0x80000000 if int(name[-4:]) % 2 else 0)

    def test_parent_before_lower_form_id_child_and_native_decimal_groups(self):
        blob = fixture.fixtures()[fixture.QUICK]
        roots = signatures(blob, 24)
        parent = (b"CELL", fixture.PARENT_ID & 0xFFFFFF, 0)
        child = (b"REFR", fixture.CHILD_ID & 0xFFFFFF, 0)
        self.assertLess(roots.index(parent), roots.index(child))
        self.assertGreater(parent[1], child[1])
        self.assertNotIn(child, signatures(fixture.fixtures()[fixture.CANCEL], 24))
        # Find each CELL record and check its enclosing block/sub-block labels.
        def visit(start, end, groups=()):
            while start < end:
                signature, size = struct.unpack_from("<4sI", blob, start)
                if signature == b"GRUP":
                    label, kind = struct.unpack_from("<II", blob, start + 8)
                    visit(start + 24, start + size, groups + ((label, kind),))
                    start += size
                else:
                    if signature == b"CELL":
                        identity = struct.unpack_from("<I", blob, start + 12)[0] & 0xFFFFFF
                        self.assertEqual(groups[-2:], ((identity % 10, 2), (identity // 10 % 10, 3)))
                    start += 24 + size
            self.assertEqual(start, end)
        visit(0, len(blob))

    def test_deleted_reference_overrides_and_manual_navmesh_control(self):
        data = fixture.fixtures()
        base, override = signatures(data[fixture.MASTER], 24), signatures(data[fixture.AUTO], 24)
        for index in range(fixture.REFERENCES):
            self.assertIn((b"REFR", 0x2000 + index, 0), base)
            self.assertIn((b"REFR", 0x2000 + index, 0x20), override)
        self.assertIn((b"NAVM", fixture.NAVM_ID & 0xFFFFFF, 0x20), override)
        self.assertIn(fixture.UNUSED.encode() + b"\0", data[fixture.AUTO])
        self.assertNotIn(fixture.UNUSED.encode() + b"\0", data[fixture.QUICK])

    def test_accepts_partial_cancellation_and_completion_for_both_stage_shapes(self):
        for state in ("running", "canceled", "succeeded"):
            for dry in (True, False):
                for masters in (True, False):
                    fixture.validate_state(snapshot(state, dry, masters))

    def test_rejects_false_success_count_drift_and_unbounded_mutation_steps(self):
        for mutate in (
            lambda s: s["progress"]["detail"].update(lastMutations=17),
            lambda s: s["progress"]["detail"].update(retainedRecords=1),
            lambda s: s["summary"].update(applied=2),
            lambda s: s["result"]["files"][0].update(workComplete=False),
            lambda s: s["result"]["files"][0].update(complete=False),
            lambda s: s.update(cursorRetained=True),
            lambda s: s.update(dryRun=True),
        ):
            state = deepcopy(snapshot("succeeded"))
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)
        state = snapshot("succeeded", masters=True)
        state["result"]["files"][0]["operations"]["cleanMasters"]["complete"] = False
        with self.assertRaises(AssertionError):
            fixture.validate_state(state)


if __name__ == "__main__":
    unittest.main()
