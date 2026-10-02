import struct
import unittest
from merged_fixture import fixtures, BASE, LEFT, RIGHT, A, B, C, D
from test_copy_modes_fixture import records


def entries(data, identity, kind):
    output = []
    def visit(start, end):
        while start < end:
            signature, size = struct.unpack_from("<4sI", data, start)
            if signature == b"GRUP":
                visit(start + 24, start + size)
                start += size
                continue
            if struct.unpack_from("<I", data, start + 12)[0] == identity:
                offset, stop = start + 24, start + 24 + size
                while offset < stop:
                    sub, length = struct.unpack_from("<4sH", data, offset)
                    if sub == kind:
                        output.append(struct.unpack_from("<I", data, offset + (10 if kind == b"LVLO" else 6))[0])
                    offset += 6 + length
            start += 24 + size
    visit(0, len(data))
    return output


class MergedFixtureTest(unittest.TestCase):
    def test_independent_siblings_remove_duplicate_and_add_different_entries(self):
        scene = fixtures()
        for name, expected in ((BASE, [A, A, B]), (LEFT, [A, C]), (RIGHT, [A, A, B, D])):
            self.assertEqual(entries(scene[name], 0x01000800, b"LVLO"), expected)
        for name in (LEFT, RIGHT):
            header = records(scene[name])[0][2]
            self.assertEqual(header[b"MAST"], BASE.encode() + b"\0")
        right = records(scene[RIGHT])[1][2]
        self.assertEqual(right[b"LVLD"], bytes([23]))
        self.assertEqual(struct.unpack("<IIf", right[b"COED"]), (0, 0, 0.5))

    def test_ordered_appends_and_faulty_reorder_are_distinct(self):
        scene = fixtures()
        for name, expected in ((BASE, [A]), (LEFT, [A, C]), (RIGHT, [A, D])):
            self.assertEqual(entries(scene[name], 0x01000802, b"LNAM"), expected)
        self.assertEqual(entries(scene[BASE], 0x01000803, b"LNAM"), [A, B])
        self.assertEqual(entries(scene[LEFT], 0x01000803, b"LNAM"), [B, A, C])


if __name__ == "__main__":
    unittest.main()
