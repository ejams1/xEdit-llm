import unittest
from selective_cleaning_fixture import fixtures, ITM, UDR
from report_fixture import signatures

class SelectiveCleaningFixtureTest(unittest.TestCase):
    def test_jobs_have_equivalent_independent_itm_udr_nav_and_parent_controls(self):
        data = fixtures()
        self.assertEqual(data[ITM], data[UDR])
        for name in (ITM, UDR):
            records = signatures(data[name], 24)
            self.assertIn((b'KYWD', 0x800, 0), records)
            self.assertIn((b'KYWD', 0x801, 0x80000000), records)
            self.assertIn((b'CELL', 0x820, 0), records)
            self.assertIn((b'REFR', 0x830, 0x20), records)
            self.assertIn((b'NAVM', 0x831, 0x20), records)

if __name__ == '__main__': unittest.main()
