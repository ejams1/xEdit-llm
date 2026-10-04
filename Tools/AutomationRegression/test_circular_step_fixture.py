"""Independent fixture edge/identity checks; native execution is still required."""
import struct
import unittest

import circular_step_fixture as fixture


class CircularStepFixtureTests(unittest.TestCase):
    def test_fixture_has_exact_chain_and_closed_cycles_in_each_signature(self):
        data = fixture.fixture_bytes()
        records = fixture.read_lists(data[fixture.PLUGIN])
        self.assertEqual(len(records), 6 + fixture.CHAIN_COUNT + fixture.LONG_CYCLE_COUNT)
        for index, signature in enumerate(fixture.SIGNATURES):
            first = 0x01000800 + index * 2
            self.assertEqual(records[first]["signature"], signature.decode())
            self.assertEqual(records[first]["edges"], [first + 1])
            self.assertEqual(records[first + 1]["edges"], [first])
        for node in range(fixture.CHAIN_COUNT):
            expected = [0x01001000 + node + 1] if node < fixture.CHAIN_COUNT - 1 else []
            self.assertEqual(records[0x01001000 + node]["edges"], expected)
        for node in range(fixture.LONG_CYCLE_COUNT):
            self.assertEqual(records[0x01002000 + node]["edges"], [
                0x01002000 + (node + 1) % fixture.LONG_CYCLE_COUNT])
        count, next_id = struct.unpack_from("<II", data[fixture.PLUGIN], 34)
        self.assertEqual(count, len(records))
        self.assertGreater(next_id, max(records) & 0xFFFFFF)

    def test_depth_variant_exceeds_budget_without_reusing_any_form_id(self):
        records = fixture.read_lists(fixture.fixture_bytes(True)[fixture.PLUGIN])
        self.assertEqual(len(records), 6 + fixture.DEPTH_CAPACITY_COUNT)
        self.assertGreater(fixture.DEPTH_CAPACITY_COUNT, 1024)
        self.assertFalse(any("LongCycle" in value["name"] for value in records.values()))
        for node in range(fixture.DEPTH_CAPACITY_COUNT - 1):
            self.assertEqual(records[0x01001000 + node]["edges"], [0x01001000 + node + 1])
        self.assertEqual(records[0x01001000 + fixture.DEPTH_CAPACITY_COUNT - 1]["edges"], [])

    def test_later_winners_break_one_master_cycle_and_preserve_another(self):
        data = fixture.fixture_bytes()
        master = fixture.read_lists(data[fixture.MASTER])
        override = fixture.read_lists(data[fixture.OVERRIDE])
        self.assertEqual(set(master), set(range(0x01003000, 0x01003004)))
        self.assertEqual(set(override), {0x01003001, 0x01003002})
        self.assertEqual(master[0x01003001]["edges"], [0x01003000])
        self.assertEqual(override[0x01003001]["edges"], [])
        self.assertEqual(master[0x01003002]["edges"], override[0x01003002]["edges"])
        self.assertEqual(override[0x01003002]["edges"], [0x01003003])
        self.assertEqual(master[0x01003003]["edges"], [0x01003002])
        self.assertNotEqual(master[0x01003002]["name"], override[0x01003002]["name"])
        self.assertIn(fixture.MASTER.encode() + b"\0", data[fixture.OVERRIDE])

    def test_parser_refuses_corrupt_record_boundaries(self):
        data = fixture.fixture_bytes()[fixture.PLUGIN]
        with self.assertRaises((AssertionError, struct.error)):
            fixture.read_lists(data[:-1])

    def test_locator_identity_normalizes_display_spacing_without_changing_owner(self):
        self.assertEqual(fixture.locator_identity({"file": "winner.esp", "formId": "01 003002"}),
                         ("winner.esp", "01003002"))


if __name__ == "__main__":
    unittest.main()
