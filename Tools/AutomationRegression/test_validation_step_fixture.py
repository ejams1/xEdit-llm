"""Fixture integrity and acceptance-assertion checks, not native execution."""
from copy import deepcopy
import struct
import unittest

from itm_fixture import read_keywords
import validation_step_fixture as fixture


def snapshot(state="running"):
    complete = state == "succeeded"
    return {"state": state, "findingsComplete": complete,
            "cursorRetained": state == "running",
            "progress": {"completed": int(complete), "total": 1,
                         "remaining": int(not complete), "detail": {
                             "lastWorkUnits": 128, "workLimit": 128,
                             "retainedDepth": 0 if complete else 3,
                             "softBudgetMs": 20, "nativeCallsPreemptible": False,
                             "fileComplete": complete}},
            "result": {"files": [{"complete": complete}]}}


class ValidationStepFixtureTests(unittest.TestCase):
    def test_large_fixture_preserves_payloads_and_alternates_header_only_changes(self):
        data = fixture.fixture_bytes()
        master = read_keywords(data[fixture.MASTER])
        override = read_keywords(data[fixture.PLUGIN])
        self.assertEqual(len(master), fixture.COUNT)
        self.assertEqual(set(master), set(override))
        for name, (form_id, flags) in override.items():
            index = int(name[-4:])
            self.assertEqual(master[name], (form_id, 0))
            self.assertEqual(flags, 0 if index % 2 == 0 else 0x400)
        for blob in data.values():
            # Independently decode TES4/HEDR count and next available object ID.
            self.assertEqual(blob[24:28], b"HEDR")
            count, next_id = struct.unpack_from("<II", blob, 34)
            self.assertEqual(count, fixture.COUNT)
            self.assertEqual(next_id, 0x800 + fixture.COUNT)

    def test_capacity_fixture_exceeds_retention_with_identical_records(self):
        data = fixture.fixture_bytes(capacity=True)
        master = read_keywords(data[fixture.MASTER])
        override = read_keywords(data[fixture.PLUGIN])
        self.assertEqual(master, override)
        self.assertEqual(len(override), fixture.CAPACITY_COUNT)
        self.assertGreater(len(override), 5000)

    def test_progress_accepts_partial_canceled_failed_and_completed_snapshots(self):
        for state in ("running", "canceled", "failed", "succeeded"):
            fixture.validate_progress(snapshot(state))

    def test_progress_rejects_work_overruns_or_claimed_native_preemption(self):
        for field, value in (("lastWorkUnits", 129), ("retainedDepth", 65),
                             ("nativeCallsPreemptible", True)):
            state = snapshot()
            state["progress"]["detail"][field] = value
            with self.assertRaises(AssertionError):
                fixture.validate_progress(state)

    def test_progress_rejects_success_with_incomplete_file_or_retained_stack(self):
        success = snapshot("succeeded")
        for mutate in (lambda s: s["result"]["files"][0].update(complete=False),
                       lambda s: s["progress"]["detail"].update(retainedDepth=1),
                       lambda s: s["progress"].update(remaining=1)):
            state = deepcopy(success)
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_progress(state)

    def test_canceled_job_must_not_advertise_complete_findings(self):
        state = snapshot("canceled")
        state["findingsComplete"] = True
        with self.assertRaises(AssertionError):
            fixture.validate_progress(state)

    def test_terminal_job_must_release_its_cursor(self):
        for terminal in ("canceled", "failed", "succeeded"):
            state = snapshot(terminal)
            state["cursorRetained"] = True
            with self.assertRaises(AssertionError):
                fixture.validate_progress(state)

    def test_findings_paging_drains_every_page_and_refuses_nonadvancing_pages(self):
        class Client:
            def __init__(self, empty=False):
                self.offsets = []
                self.empty = empty

            def call(self, command, /, **args):
                self.offsets.append(args["offset"])
                self.assert_command = command
                return {"total": 80, "findings": [] if self.empty else
                        list(range(args["offset"], min(args["offset"] + args["limit"], 80)))}

        client = Client()
        self.assertEqual(fixture.findings(client, "job-fixture"), list(range(80)))
        self.assertEqual(client.offsets, [0, 37, 74])
        self.assertEqual(client.assert_command, "jobs.findings")
        with self.assertRaises(AssertionError):
            fixture.findings(Client(empty=True), "job-fixture")


if __name__ == "__main__":
    unittest.main()
