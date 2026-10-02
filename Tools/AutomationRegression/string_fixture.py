"""Lossless string/encoding acceptance against an MO2-launched FO4 daemon."""

import argparse
from pathlib import Path
import struct

from itm_fixture import Client, record, subrecord

PLUGIN = "AutomationStringValues.esp"
VALUES = {
    "AutomationStringLong": " " + "long text " * 40 + "\n ",
    "AutomationStringEmpty": "",
    "AutomationStringWhitespace": " \t\r\n ",
    "AutomationStringUnicode": "  Français Привет 日本語 😀\n ",
}


def fixture_bytes():
    header = subrecord(b"HEDR", struct.pack("<fII", 1.0, 5, 0x900))
    header += subrecord(b"MAST", b"Fallout4.esm\0") + subrecord(b"DATA", b"\0" * 8)
    messages = b""
    for index, (name, text) in enumerate(VALUES.items(), 0x800):
        payload = subrecord(b"EDID", name.encode() + b"\0")
        payload += subrecord(b"DESC", text.encode("utf-8") + b"\0")
        payload += subrecord(b"DNAM", struct.pack("<I", 0))
        payload += subrecord(b"INAM", struct.pack("<I", 0))
        payload += subrecord(b"TNAM", struct.pack("<I", 2))
        messages += record(b"MESG", payload, form_id=0x01000000 + index)
    group = struct.pack("<4sI4sIHHHH", b"GRUP", 24 + len(messages), b"MESG", 0, 0, 0, 0, 0) + messages
    return record(b"TES4", header) + group


def exercise(client, phase):
    listing = client.call("records.list", file=PLUGIN, signature="MESG")
    assert not listing["truncated"], listing
    locators = {r["object"]["editorId"]: {**r["locator"], "path": "DESC"} for r in listing["records"]}
    assert set(locators) == set(VALUES), locators
    for name, original in VALUES.items():
        replacement = ("  修改 Привет 😀 " if name.endswith("Unicode") else "  replacement ") + "x" * 240 + "\n "
        expected = original if phase == "exercise" else replacement
        full = client.call("elements.get_value", **locators[name])["values"]
        assert full["editValue"] == expected, full
        assert full["nativeValue"]["kind"] == "string", full
        assert full["nativeValue"]["value"] == expected, full
        assert not full["truncated"] and full["whitespacePreserved"], full
        assert full["length"] == len(expected.encode("utf-16-le")) // 2, full
        assert full["utf8Bytes"] == len(expected.encode("utf-8")), full
        if name.endswith("Unicode"):
            assert full["storageEncoding"]["codePage"] == 65001, full
        preview = client.call("elements.get", **locators[name])["object"]["previewMetadata"]["editValue"]
        assert preview["length"] == full["length"], preview
        assert preview["truncated"] == (len(expected.strip()) > 160), preview
        if phase == "exercise":
            if name.endswith("Whitespace"):
                # ASCII storage chooses CP-1252. New unrepresentable text must
                # fail before storage changes; a fresh full read proves that.
                try:
                    client.call("elements.set_native_value", **locators[name], kind="string", value="日本語")
                except RuntimeError as error:
                    assert isinstance(error.args[0], dict) and error.args[0].get("ok") is False, error
                else:
                    raise AssertionError("Lossy write unexpectedly succeeded")
                assert client.call("elements.get_value", **locators[name])["values"]["editValue"] == original
            client.call("elements.set_native_value", **locators[name], kind="string", value=replacement)
            assert client.call("elements.get_value", **locators[name])["values"]["editValue"] == replacement
    if phase == "exercise":
        client.call("session.save", files=[PLUGIN])
        client.call("session.flush")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["generate", "exercise", "verify"])
    parser.add_argument("--overlay", required=True, type=Path)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        args.overlay.mkdir(parents=True, exist_ok=True)
        with (args.overlay / PLUGIN).open("xb") as stream:
            stream.write(fixture_bytes())
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Live phases require --exe, --pid and --artifacts")
        exercise(Client(args.exe, args.pid, args.artifacts), args.phase)


if __name__ == "__main__":
    main()
