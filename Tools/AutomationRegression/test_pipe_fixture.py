import unittest
from pipe_fixture import LIMIT, padded_ping


class PipeFixtureTest(unittest.TestCase):
    def test_exact_encoded_boundaries(self):
        import json
        for size in (LIMIT - 1, LIMIT, LIMIT + 1):
            wire = padded_ping(size)
            self.assertEqual(len(wire), size)
            self.assertEqual(json.loads(wire)["args"]["padding"], "é")


if __name__ == "__main__":
    unittest.main()
