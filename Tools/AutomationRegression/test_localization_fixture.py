import struct
import unittest
from localization_fixture import TABLES, encode_table, decode_table, plugin_bytes, read_plugin

class LocalizationFixtureTest(unittest.TestCase):
    def test_all_table_formats(self):
        for kind, rows in TABLES.items():
            encoded = encode_table(rows, kind)
            self.assertEqual(decode_table(encoded, kind), rows)
            self.assertEqual(len(encoded), 8 + 8 * len(rows) + struct.unpack_from('<I', encoded, 4)[0])

    def test_shared_ids_and_zero(self):
        flag, rows = read_plugin(plugin_bytes())
        self.assertTrue(flag)
        self.assertEqual(rows['SharedA']['FULL'], rows['SharedB']['FULL'])
        self.assertEqual(rows['SharedB']['DESC'], b'\0' * 4)
        self.assertEqual(len(rows['Unicode']['FULL']), 4)

    def test_malformed_tables(self):
        for kind, rows in TABLES.items():
            good = encode_table(rows, kind)
            for bad in (good[:7], good[:-1], struct.pack('<II', 100, 0) + good[8:]):
                with self.assertRaises(ValueError): decode_table(bad, kind)

if __name__ == '__main__': unittest.main()
