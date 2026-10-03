import unittest
from report_fixture import fixtures, signatures, BASE, DIRTY, QUICK, CLEAN

class ReportFixtureTest(unittest.TestCase):
    def test_saved_snapshot_has_distinct_itm_flag_udr_nav_cases(self):
        for game, size in (('fo4', 24), ('tes4', 20)):
            files = fixtures(game)
            dirty = signatures(files[DIRTY], size)
            quick = signatures(files[QUICK], size)
            sig = b'GLOB' if game == 'tes4' else b'KYWD'
            self.assertIn((sig, 0x800, 0), dirty)
            self.assertIn((sig, 0x801, 0x80000000), dirty)
            self.assertIn((b'REFR', 0x830, 0x20), dirty)
            self.assertEqual(any(sig == b'NAVM' and flags == 0x20 for sig, _, flags in dirty), game == 'fo4')
            self.assertFalse(any(sig == b'NAVM' for sig, _, _ in quick))
            self.assertEqual(signatures(files[CLEAN], size), [(b'TES4', 0, 0)])
            self.assertIn((b'REFR', 0x830, 0), signatures(files[BASE], size))

if __name__ == '__main__': unittest.main()
