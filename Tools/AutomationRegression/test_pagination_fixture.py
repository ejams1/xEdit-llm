import unittest
from pagination_fixture import COUNT, fixture_bytes


class PaginationFixtureTest(unittest.TestCase):
    def test_fixture_has_distinct_large_record_set(self):
        data = fixture_bytes()
        self.assertEqual(data.count(b"KYWD"), COUNT + 1)  # GRUP signature and records
        self.assertIn(b"AutomationPage0000\0", data)
        self.assertIn(f"AutomationPage{COUNT - 1:04d}\0".encode(), data)


if __name__ == "__main__":
    unittest.main()
