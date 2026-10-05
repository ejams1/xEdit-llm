"""Inventory witnesses and native acceptance assertion integrity only."""
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

import lod_step_fixture as fixture


def snapshot(state="running", complete=False):
    return {"state": state, "terminal": state != "running", "cursorRetained": state == "running",
        "findingsComplete": state == "succeeded", "dryRun": False,
        "summary": {"worldspaceCount": 1, "completedWorldspaces": int(complete)},
        "result": {"worldspaces": [{"complete": complete, "nativeComplete": True,
            "inventoryComplete": complete, "generatedFiles": 1,
            "artifacts": [{"path": "Meshes\\test.bin", "bytes": 12, "scratch": False}]}]},
        "progress": {"total": 1, "completed": int(complete), "remaining": int(not complete), "detail": {
            "lastWorkUnits": 128, "workLimit": 128, "softBudgetMs": 20, "nativeCallsPreemptible": False,
            "nativeUnits": 1, "nativeUnitLimit": 1, "inventory": {"workUnits": 128, "workLimit": 16384,
            "artifactCount": 1, "fileLimit": 1024, "artifactBytes": 80, "byteLimit": 262144,
            "directoriesSeen": 2, "directoryLimit": 256}}}}


class LODStepTests(unittest.TestCase):
    def test_inventory_witness_paths_bytes_and_freshness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            witnesses = fixture.witnesses(root)
            self.assertEqual(len(witnesses), 400)
            self.assertGreater(len(witnesses), 128)
            for name, size in witnesses.items():
                self.assertEqual((root / name.replace("\\", "/")).stat().st_size, size)
            with self.assertRaises(FileExistsError):
                fixture.witnesses(root)

    def test_accepts_running_canceled_failed_and_complete_states(self):
        for state in ("running", "canceled", "failed", "succeeded"):
            fixture.validate_state(snapshot(state, state == "succeeded"))

    def test_rejects_inventory_completion_counts_limits_and_retention_lies(self):
        for mutate in (
            lambda s: s["result"]["worldspaces"][0].update(inventoryComplete=False),
            lambda s: s["result"]["worldspaces"][0].update(generatedFiles=2),
            lambda s: s["summary"].update(worldspaceCount=2),
            lambda s: s["progress"]["detail"].update(nativeUnits=2),
            lambda s: s["progress"]["detail"]["inventory"].update(artifactCount=1025),
            lambda s: s["progress"]["detail"]["inventory"].update(artifactBytes=262145),
            lambda s: s["progress"]["detail"]["inventory"].update(directoriesSeen=257),
            lambda s: s.update(cursorRetained=True),
        ):
            value = deepcopy(snapshot("succeeded", True))
            mutate(value)
            with self.assertRaises(AssertionError):
                fixture.validate_state(value)


if __name__ == "__main__":
    unittest.main()
