"""Fixture/readback support tests; these do not execute native row mutations."""
import struct
import unittest
from row_fixture import BASE, SOURCE, TARGET, DESCRIPTION, fixtures, disk_state


class RowFixtureTest(unittest.TestCase):
    def test_source_dependencies_and_target_sentinels_prove_real_replacement(self):
        files = fixtures()
        masters, source = disk_state(files[SOURCE])
        self.assertEqual(masters, ['Fallout4.esm', BASE])
        self.assertEqual(source['RowSourceText']['fields'][b'DESC'], [DESCRIPTION.encode() + b'\0'])
        masters, target = disk_state(files[TARGET])
        self.assertEqual(masters, ['Fallout4.esm'])
        self.assertEqual(len(target), 10)
        self.assertNotEqual(target['RowTextA']['fields'][b'DESC'], source['RowSourceText']['fields'][b'DESC'])
        self.assertEqual([struct.unpack('<I', value)[0] for value in target['RowListA']['fields'][b'LNAM']],
                         list(range(0x01000810, 0x01000814)))
        self.assertEqual([struct.unpack('<I', value)[0] for value in source['RowSourceList']['fields'][b'LNAM']],
                         list(range(0x01000800, 0x01000804)))


if __name__ == '__main__': unittest.main()
