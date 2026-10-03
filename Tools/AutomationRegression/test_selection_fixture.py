import unittest
from selection_fixture import fixtures, SCENE, TARGETS
from report_fixture import signatures

class SelectionFixtureTest(unittest.TestCase):
    def test_nested_owner_payload_and_group_sources_are_distinct_from_empty_targets(self):
        files = fixtures()
        source = signatures(files[SCENE], 24)
        self.assertEqual(len(source), 7)
        for sig, identity in ((b'KYWD', 0x800), (b'KYWD', 0x801), (b'STAT', 0x810),
                              (b'CELL', 0x820), (b'REFR', 0x830), (b'NAVM', 0x831)):
            self.assertIn((sig, identity, 0), source)
        self.assertIn(b'ReportInterior\0', files[SCENE])
        self.assertIn(b'ReportDeletedRef\0', files[SCENE])
        for name in TARGETS: self.assertEqual(signatures(files[name], 24), [(b'TES4', 0, 0)])

if __name__ == '__main__': unittest.main()
