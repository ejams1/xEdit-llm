import struct
import unittest
from injected_fixture import fixtures, BASE, PROVIDER
from test_copy_modes_fixture import records


class InjectedFixtureTest(unittest.TestCase):
    def test_provider_injects_absent_base_identity_referred_by_base(self):
        scene = fixtures()
        base = [row for row in records(scene[BASE]) if row[0] == b"LVLI"]
        provider = [row for row in records(scene[PROVIDER]) if row[0] == b"LVLI"]
        self.assertEqual(len(base), 2)
        self.assertEqual(len(provider), 1)
        injected_id = provider[0][1]
        self.assertEqual(injected_id >> 24, base[0][1] >> 24)
        self.assertNotIn(injected_id, {row[1] for row in base})
        # The fixture's last LVLO is unrelated; inspect all raw subrecords to
        # verify both targets exist, avoiding a lossy dictionary parser here.
        data = scene[BASE]
        targets = []
        for offset in range(len(data) - 18):
            if data[offset:offset + 6] == b"LVLO\x0c\x00":
                targets.append(struct.unpack_from("<I", data, offset + 10)[0])
        self.assertEqual(targets, [injected_id, base[1][1]])


if __name__ == "__main__":
    unittest.main()
