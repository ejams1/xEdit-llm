import struct
import unittest
from reachability_fixture import fixtures, BASE, PATCH

class ReachabilityFixtureTest(unittest.TestCase):
    def test_cross_file_roots_and_cycles(self):
        files = fixtures()
        base, patch = files[BASE], files[PATCH]
        self.assertEqual(struct.unpack_from('<I', base, 24 + 6 + 4)[0], 4)
        self.assertEqual(base.count(b'LNAM'), 4)
        self.assertEqual(patch.count(b'DFOB'), 2)
        self.assertIn(b'DATA\x04\x00' + struct.pack('<I', 0x01000800), patch)
        for identity in (0x01000800, 0x01000801, 0x01000802, 0x01000803):
            self.assertIn(subrecord_id(identity), base)

def subrecord_id(identity): return b'LNAM\x04\x00' + struct.pack('<I', identity)

if __name__ == '__main__': unittest.main()
