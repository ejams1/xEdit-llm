import struct
import unittest
from modgroups_fixture import fixtures, BASE, LEFT, RIGHT, ITEMS, KEEP

class ModGroupsFixtureTest(unittest.TestCase):
    def test_override_chain_is_same_identity(self):
        for name, data in fixtures().items():
            self.assertEqual(data.count(b'KYWD'), 2)
            self.assertIn(struct.pack('<I', 0x01000800), data)
            self.assertEqual(data.count(b'MAST'), {BASE: 1, LEFT: 2, RIGHT: 3}[name])

    def test_native_source_target_section(self):
        self.assertEqual(ITEMS, ['@' + LEFT, '#' + RIGHT])
        self.assertEqual(KEEP, '[Keep]\n' + '\n'.join(ITEMS) + '\n')

if __name__ == '__main__': unittest.main()
