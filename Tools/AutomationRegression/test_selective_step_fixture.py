"""Fixture bytes and native acceptance assertions, not Pascal/runtime checks."""
from copy import deepcopy
import struct
import unittest

from itm_fixture import read_keywords
from report_fixture import signatures
import selective_step_fixture as fixture


def snapshot(state="running", dry=False):
    succeeded = state == "succeeded"
    applied = 0 if dry else (2 if succeeded else 1)
    rows = [{"outcome": "applied" if index < applied else "planned",
             "locator": {"formId": f"010008{index:02X}"}} for index in range(2)]
    rows.append({"outcome": "skipped", "locator": {"formId": "01002200"}})
    return {"state": state, "dryRun": dry, "terminal": state != "running",
            "cursorRetained": state == "running", "findingsComplete": succeeded,
            "summary": {"applied": applied}, "progress": {
                "completed": int(succeeded), "total": 1, "remaining": int(not succeeded),
                "detail": {"lastWorkUnits": 16, "workLimit": 128,
                           "lastMutations": 0 if dry else 1, "mutationLimit": 16,
                           "nativeCallsPreemptible": False, "softBudgetMs": 20}},
            "result": {"files": [{"records": rows, "applied": applied, "planned": 2,
                                  "skipped": 1, "planningComplete": True, "complete": succeeded}]}}


class SelectiveStepFixtureTests(unittest.TestCase):
    def test_itm_fixture_alternates_identical_and_flag_only_overrides(self):
        data = fixture.fixtures()
        master, override = map(read_keywords, (data[fixture.MASTER], data[fixture.ITM]))
        self.assertEqual(len(master), fixture.COUNT)
        self.assertEqual(set(master), set(override))
        for name, (form_id, flags) in override.items():
            self.assertEqual(master[name], (form_id, 0))
            self.assertEqual(flags, 0x80000000 if int(name[-4:]) % 2 else 0)

    def test_udr_fixture_has_deleted_overrides_of_every_master_reference(self):
        data = fixture.fixtures()
        base = signatures(data[fixture.MASTER], 24)
        udr = signatures(data[fixture.UDR], 24)
        for index in range(fixture.COUNT):
            self.assertIn((b"REFR", 0x2000 + index, 0), base)
            self.assertIn((b"REFR", 0x2000 + index, 0x20), udr)
        self.assertIn((b"NAVM", fixture.NAVM_ID & 0xFFFFFF, 0x20), udr)
        self.assertIn((b"CELL", fixture.CELL_ID & 0xFFFFFF, 0), udr)
        self.assertLessEqual(len(udr) + len(signatures(data[fixture.ITM], 24)), 1000)
        for name, blob in data.items():
            count = struct.unpack_from("<I", blob, 34)[0]
            self.assertEqual(count, len(signatures(blob, 24)) - 1, name)

    def test_cell_groups_use_native_decimal_object_id_labels(self):
        blob = fixture.fixtures()[fixture.UDR]
        header_size = struct.unpack_from("<I", blob, 4)[0]
        top = 24 + header_size
        self.assertEqual(blob[top:top + 4], b"GRUP")
        self.assertEqual(blob[top + 8:top + 12], b"CELL")
        block = top + 24
        sub_block = block + 24
        label, kind = struct.unpack_from("<II", blob, block + 8)
        sub_label, sub_kind = struct.unpack_from("<II", blob, sub_block + 8)
        object_id = fixture.CELL_ID & 0xFFFFFF
        self.assertEqual((label, kind), (object_id % 10, 2))
        self.assertEqual((sub_label, sub_kind), (object_id // 10 % 10, 3))

    def test_ledger_accepts_partial_cancel_and_success_without_rollback_claims(self):
        for state in ("running", "canceled", "succeeded"):
            for dry in (False, True):
                fixture.validate_state(snapshot(state, dry))

    def test_ledger_refuses_mutation_before_completed_plan_or_in_dry_run(self):
        state = snapshot()
        state["result"]["files"][0]["planningComplete"] = False
        with self.assertRaises(AssertionError):
            fixture.validate_state(state)
        state = snapshot()
        state["dryRun"] = True
        with self.assertRaises(AssertionError):
            fixture.validate_state(state)

    def test_ledger_refuses_overrun_duplicate_identity_and_false_success(self):
        for mutate in (
            lambda s: s["progress"]["detail"].update(lastMutations=17),
            lambda s: s["result"]["files"][0]["records"][1]["locator"].update(formId="01000800"),
            lambda s: s["result"]["files"][0].update(applied=99),
            lambda s: s.update(cursorRetained=True),
            lambda s: s["result"]["files"][0].update(complete=False),
        ):
            state = deepcopy(snapshot("succeeded"))
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)

    def test_start_preserves_omitted_true_and_false_dry_run(self):
        class Client:
            def __init__(self):
                self.calls = []

            def call(self, command, /, **args):
                self.calls.append((command, args))
                return {"jobId": "job-fixture"}

        client = Client()
        for dry in (None, True, False):
            self.assertEqual(fixture.start(client, fixture.ITM_KIND, fixture.ITM, dry), "job-fixture")
        self.assertNotIn("dryRun", client.calls[0][1])
        self.assertIs(client.calls[1][1]["dryRun"], True)
        self.assertIs(client.calls[2][1]["dryRun"], False)


if __name__ == "__main__":
    unittest.main()
