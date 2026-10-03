import struct
import unittest
from seq_fixture import fixtures, DUMMY, BASE, PATCH, EXPECTED
from test_copy_modes_fixture import records


class SeqFixtureTest(unittest.TestCase):
    def test_new_enabled_and_master_enable_flip_are_independently_observable(self):
        scene = fixtures()
        self.assertFalse(any(row[0] == b"QUST" for row in records(scene[DUMMY])))
        base = {row[1]: row[2] for row in records(scene[BASE]) if row[0] == b"QUST"}
        patch = [row for row in records(scene[PATCH]) if row[0] == b"QUST"]
        flags = lambda fields: struct.unpack_from("<H", fields[b"DNAM"])[0]
        eligible = [identity for _, identity, fields in patch
                    if flags(fields) & 1 and (identity not in base or not flags(base[identity]) & 1)]
        self.assertEqual(eligible, EXPECTED)
        self.assertEqual(len(patch), 5)
        self.assertTrue(all(len(fields[b"DNAM"]) == 12 for _, _, fields in patch))
        self.assertEqual(len(struct.pack("<3I", *eligible)), 12)


if __name__ == "__main__": unittest.main()
