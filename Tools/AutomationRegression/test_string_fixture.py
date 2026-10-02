"""Source and fixture checks only; Delphi/game-backed validation is pending."""

from pathlib import Path
import struct
import unittest

import string_fixture

ROOT = Path(__file__).resolve().parents[2]


class StringFixtureTests(unittest.TestCase):
    def test_fixture_bytes_preserve_whitespace_empty_and_multilingual_text(self):
        fixture = string_fixture.fixture_bytes()
        for value in string_fixture.VALUES.values():
            payload = value.encode("utf-8") + b"\0"
            self.assertIn(b"DESC" + struct.pack("<H", len(payload)) + payload, fixture)

    def test_lossy_checks_precede_storage_resize(self):
        source = (ROOT / "Core/wbInterface.pas").read_text(encoding="utf-8-sig")
        for method, ending in [("TwbStringDef.FromStringNative", "TwbStringDef.FromStringTransform"),
                               ("TwbLenStringDef.FromEditValue", "TwbLenStringDef.FromNativeValue")]:
            body = source.split("procedure " + method + "(", 1)[1].split("procedure " + ending + "(", 1)[0]
            self.assertLess(body.index("cannot be represented without loss"), body.index("aElement.RequestStorageChange"))


if __name__ == "__main__":
    unittest.main()
