import struct
import unittest
from vwd_fixture import fixtures, SCENE, OUTPUT

class VWDFixtureTest(unittest.TestCase):
    def test_classic_headers_and_exterior_interior_ancestry(self):
        data = fixtures()[SCENE]
        size, = struct.unpack_from('<I', data, 4)
        self.assertEqual(data[size + 20:size + 24], b'GRUP')
        self.assertIn(b'eligible.nif\0', data)
        self.assertIn(b'missing.nif\0', data)
        self.assertEqual(data.count(b'REFR'), 4)
        kinds, ancestry = [], {}
        def visit(start, end, parents=()):
            while start < end:
                sig, size = struct.unpack_from('<4sI', data, start)
                if sig == b'GRUP':
                    kind = struct.unpack_from('<I', data, start + 12)[0]
                    kinds.append(kind)
                    visit(start + 20, start + size, parents + (kind,))
                    start += size
                else:
                    if sig == b'REFR':
                        identity = struct.unpack_from('<I', data, start + 12)[0]
                        ancestry[identity & 0xFFFFFF] = parents
                    start += size + 20
            self.assertEqual(start, end)
        visit(0, len(data))
        self.assertTrue({0, 1, 2, 3, 4, 5, 6, 9}.issubset(kinds))
        self.assertEqual(ancestry, {0x830: (0, 1, 4, 5, 6, 9),
                                   0x831: (0, 1, 4, 5, 6, 9),
                                   0x832: (0, 1, 4, 5, 6, 9),
                                   0x833: (0, 2, 3, 6, 9)})
        self.assertIn(b'VWDInterior\0', data)
        self.assertEqual(len(fixtures()[OUTPUT]), 20 + struct.unpack_from('<I', fixtures()[OUTPUT], 4)[0])

if __name__ == '__main__': unittest.main()
