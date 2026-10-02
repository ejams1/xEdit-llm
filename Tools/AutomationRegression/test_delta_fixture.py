import unittest
from delta_fixture import fixtures, MASTER, BASE, COMPARE
from itm_fixture import read_keywords


class DeltaFixtureTest(unittest.TestCase):
    def test_selected_baseline_differs_from_oldest_master(self):
        scene = fixtures()
        master, base, newer = (read_keywords(scene[name]) for name in (MASTER, BASE, COMPARE))
        self.assertEqual(master["DeltaOldestValue"], newer["DeltaOldestValue"])
        self.assertEqual(base["DeltaBaselineOverride"][0], newer["DeltaOldestValue"][0])
        self.assertNotIn("DeltaOldestValue", base)
        self.assertEqual(base["DeltaIdentical"], newer["DeltaIdentical"])
        self.assertEqual(base["DeltaFlagOnly"][0], newer["DeltaFlagOnly"][0])
        self.assertNotEqual(base["DeltaFlagOnly"][1], newer["DeltaFlagOnly"][1])
        self.assertNotIn("DeltaRemoved", newer)
        self.assertNotIn("DeltaAlreadyDeleted", newer)
        self.assertEqual(base["DeltaAlreadyDeleted"][1], 0x20)
        self.assertNotIn("DeltaNewRecord", base)


if __name__ == "__main__":
    unittest.main()
