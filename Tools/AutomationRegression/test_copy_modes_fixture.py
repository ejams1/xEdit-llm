"""Validate the binary semantic scene used by the later native acceptance run."""
import struct
import unittest
from copy_modes_fixture import fixtures, SOURCE, IDLES, WINNER


def records(data):
    result = []

    def visit(start, end):
        while start < end:
            signature, size = struct.unpack_from("<4sI", data, start)
            if signature == b"GRUP":
                visit(start + 24, start + size)
                start += size
                continue
            form_id = struct.unpack_from("<I", data, start + 12)[0]
            fields = {}
            offset, stop = start + 24, start + 24 + size
            while offset < stop:
                kind, length = struct.unpack_from("<4sH", data, offset)
                fields[kind] = data[offset + 6:offset + 6 + length]
                offset += 6 + length
            result.append((signature, form_id, fields))
            start = stop

    visit(0, len(data))
    return result


class CopyModesFixtureTests(unittest.TestCase):
    def test_spawn_source_has_nondefault_count_and_ownership(self):
        lists = [row for row in records(fixtures("fo4")[SOURCE]) if row[0] == b"LVLI"]
        self.assertEqual(len(lists), 2)
        fields = lists[1][2]
        self.assertEqual(len(fields[b"LVLO"]), 12)
        self.assertEqual(struct.unpack_from("<H", fields[b"LVLO"], 0)[0], 4)
        self.assertEqual(struct.unpack_from("<I", fields[b"LVLO"], 4)[0], lists[0][1])
        self.assertEqual(struct.unpack_from("<H", fields[b"LVLO"], 8)[0], 7)
        self.assertEqual(struct.unpack("<IIf", fields[b"COED"]), (0, 0, 0.5))

    def test_idle_scene_has_internal_external_links_and_distinct_winner(self):
        scene = fixtures("fo3")
        idles = {row[1]: row[2] for row in records(scene[IDLES]) if row[0] == b"IDLE"}
        self.assertEqual(len(idles), 4)
        self.assertEqual(struct.unpack("<II", idles[0x01000802][b"ANAM"]),
                         (0x01000803, 0x01000801))
        winner = [row for row in records(scene[WINNER]) if row[0] == b"IDLE"][0]
        self.assertEqual(winner[1], 0x01000801)
        self.assertNotEqual(winner[2][b"MODL"], idles[winner[1]][b"MODL"])
        self.assertIn(b"b_winner.kf", winner[2][b"MODL"])


if __name__ == "__main__":
    unittest.main()
