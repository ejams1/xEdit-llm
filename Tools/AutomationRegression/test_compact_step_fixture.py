"""Independent compaction fixture integrity and acceptance assertion failures."""
from copy import deepcopy
import struct
import unittest

import compact_step_fixture as fixture
from row_fixture import disk_state


def snapshot(state="running", applied=0):
    done = state == "succeeded"
    row = {"fileName": fixture.TARGET, "complete": done, "planningComplete": True,
           "preflightComplete": True, "appliedRemaps": applied, "remapCount": 2,
           "changed": bool(applied), "requiresSave": bool(applied), "remaps": [
               {"oldFormId": "02010000", "newFormId": "02000801", "outcome": "applied" if applied else "planned"},
               {"oldFormId": "02010001", "newFormId": "02000803", "outcome": "applied" if applied == 2 else "planned"}]}
    return {"state": state, "dryRun": not applied, "terminal": state != "running",
            "cursorRetained": state == "running", "findingsComplete": done,
            "summary": {"planned": 0 if applied else 2, "applied": applied}, "result": {"files": [row]}, "progress": {
                "completed": int(done), "total": 1, "remaining": int(not done), "detail": {
                    "lastWorkUnits": 1, "workLimit": 128, "totalWorkUnits": 6000, "totalWorkLimit": 1000000,
                    "retainedDepth": 0, "depthLimit": 64, "newRecordCount": 3, "recordCapacity": 3,
                    "appliedRemaps": applied, "remapCount": 2, "loadedFilesProcessed": 3,
                    "loadedFilesTotal": 3, "referrersChecked": 2, "overridesChecked": 1,
                    "relationshipsPerRemapLimit": 100000, "mutationLimit": 1,
                    "softBudgetMs": 20, "nativeCallsPreemptible": False}}}


class CompactStepTests(unittest.TestCase):
    def test_raw_fixture_counts_ownership_and_descending_ids(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            rows, _ = fixture.raw_headers(blob)
            self.assertEqual(len(rows) - 1, struct.unpack_from("<I", blob, 34)[0], name)
            self.assertEqual(len(rows), len(set(rows)), name)
        rows, _ = fixture.raw_headers(data[fixture.TARGET])
        high = [identity & 0xFFFFFF for sig, identity in rows if sig == b"KYWD" and identity & 0xFFFFFF >= 0x10000]
        self.assertEqual(high, list(reversed(range(0x10000, 0x10000 + fixture.COUNT))))
        self.assertIn((b"KYWD", 0x01000800), rows)
        self.assertIn((b"KYWD", 0x02000800), rows)

    def test_external_override_and_both_internal_external_payloads(self):
        data = fixture.fixtures()
        for target, callers in ((fixture.TARGET, fixture.CALLERS), (fixture.CANCELED, fixture.CANCEL_CALLERS)):
            names, rows = disk_state(data[callers])
            self.assertEqual(names, ["Fallout4.esm", fixture.BASE, target])
            self.assertEqual(rows["CompactHigh0000"]["identity"], 0x10000)
            for file, name in ((target, "CompactInternal"), (callers, "CompactExternal")):
                _, rows = disk_state(data[file])
                self.assertEqual([struct.unpack("<I", v)[0] for v in rows[name]["fields"][b"LNAM"]],
                                 [0x02010000, 0x02010000 + fixture.COUNT - 1])

    def test_expected_mapping_reserves_all_in_range_ids_and_remains_unique(self):
        mapped = fixture.expected_remaps()
        self.assertEqual(mapped[0x10000], 0x801)
        self.assertEqual(mapped[0x10001], 0x803)
        self.assertEqual(len(set(mapped.values())), fixture.COUNT)
        self.assertFalse(set(mapped.values()) & {0x800, 0x802, 0xA00})
        self.assertTrue(all(0x800 <= v <= 0xFFF for v in mapped.values()))

    def test_accepts_durable_partial_and_complete_progress(self):
        for state in ("running", "canceled", "failed", "succeeded"):
            fixture.validate_state(snapshot(state))
            fixture.validate_state(snapshot(state, 1))

    def test_refuses_mutation_before_preflight_and_false_counters_or_limits(self):
        for mutate in (
            lambda s: s["result"]["files"][0].update(preflightComplete=False),
            lambda s: s["result"]["files"][0].update(planningComplete=False),
            lambda s: s["result"]["files"][0].update(changed=False),
            lambda s: s["result"]["files"][0].update(appliedRemaps=2),
            lambda s: s["progress"]["detail"].update(lastWorkUnits=129),
            lambda s: s["progress"]["detail"].update(recordCapacity=4096),
            lambda s: s["progress"]["detail"].update(referrersChecked=100001),
            lambda s: s.update(cursorRetained=True),
        ):
            state = deepcopy(snapshot("canceled", 1))
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)


if __name__ == "__main__":
    unittest.main()
