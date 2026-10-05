"""Acceptance assertion tests, not execution of the native cursor."""
from copy import deepcopy
import unittest
import combined_master_scan_fixture as fixture
from test_combined_step_fixture import snapshot as combined_snapshot


def snapshot(state="running", dry=False):
    value = combined_snapshot(state, dry, masters=True)
    value["progress"]["detail"].update(masterScanWorkUnits=2208 if not dry else 0,
        masterScanWorkLimit=1000000, masterNativeUsageCalls=2202 if not dry else 0,
        masterRetainedDepth=2 if state == "running" and not dry else 0, masterDepthLimit=128)
    value["result"]["files"][0]["operations"]["cleanMasters"]["scanComplete"] = state == "succeeded" and not dry
    return value


class CombinedMasterScanTests(unittest.TestCase):
    def test_partial_canceled_failed_and_complete_apply_dry_shapes(self):
        for state in ("running", "canceled", "failed", "succeeded"):
            for dry in (True, False):
                fixture.validate_state(snapshot(state, dry))

    def test_refuses_scan_capacity_counter_lies_and_unreleased_success(self):
        for mutate in (
            lambda s: s["progress"]["detail"].update(masterScanWorkUnits=1000001),
            lambda s: s["progress"]["detail"].update(masterRetainedDepth=129),
            lambda s: s["progress"]["detail"].update(masterNativeUsageCalls=2209),
            lambda s: s["progress"]["detail"].update(masterRetainedDepth=1),
            lambda s: s["result"]["files"][0]["operations"]["cleanMasters"].update(scanComplete=False),
        ):
            state = deepcopy(snapshot("succeeded"))
            mutate(state)
            with self.assertRaises(AssertionError):
                fixture.validate_state(state)


if __name__ == "__main__":
    unittest.main()
