"""Skyrim SEQ scene proving file-local IDs with a differing loaded file order."""
import argparse
import json
from pathlib import Path
import struct
from itm_fixture import Client, subrecord

DUMMY = "AutomationSeqDummy.esm"
BASE = "AutomationSeqBase.esm"
PATCH = "AutomationSeqPatch.esp"
EXPECTED = [0x01000800, 0x02000800, 0x02000802]


def record(signature, data, identity=0, flags=0):
    return struct.pack("<4sIIIIHH", signature, len(data), flags, identity, 0, 43, 0) + data


def quest(name, identity, sge, deleted=False):
    data = subrecord(b"EDID", name.encode() + b"\0")
    data += subrecord(b"DNAM", struct.pack("<HBBII", int(sge), 50, 0, 0, 0))
    data += subrecord(b"NEXT", b"")
    return record(b"QUST", data, identity, 0x20 if deleted else 0)


def plugin(masters, body, count, esm=False):
    header = subrecord(b"HEDR", struct.pack("<fII", 1.7, count, 0x900))
    for master in masters:
        header += subrecord(b"MAST", master.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    result = record(b"TES4", header, flags=int(esm))
    if body:
        result += struct.pack("<4sI4sIHHHH", b"GRUP", len(body) + 24, b"QUST", 0, 0, 0, 0, 0) + body
    return result


def fixtures():
    base = quest("SeqWasDisabled", 0x01000800, False) + quest("SeqWasEnabled", 0x01000801, True)
    patch = quest("SeqWasDisabled", 0x01000800, True) + quest("SeqWasEnabled", 0x01000801, True)
    patch += quest("SeqNewEnabled", 0x02000800, True) + quest("SeqNewDisabled", 0x02000801, False)
    # Native eligibility has no separate Deleted exclusion. Preserve it exactly.
    patch += quest("SeqDeletedEnabled", 0x02000802, True, True)
    return {DUMMY: plugin(["Skyrim.esm"], b"", 0, True),
            BASE: plugin(["Skyrim.esm"], base, 2, True),
            PATCH: plugin(["Skyrim.esm", BASE], patch, 5)}


def assert_output(path):
    data = path.read_bytes()
    assert len(data) == len(EXPECTED) * 4, data
    assert list(struct.unpack("<3I", data)) == EXPECTED, data.hex()


def exercise(client, directory):
    output = (directory / Path(PATCH).with_suffix(".seq")).resolve()
    args = dict(file=PATCH, outputPath=str(output))
    before = client.call("session.get_dirty_state")
    plan = client.call("exports.seq", **args)
    assert plan["complete"] and plan["dryRun"] and not plan["written"] and not plan["changed"], plan
    assert plan["questCount"] == 3 and plan["bytes"] == 12, plan
    assert plan["skippedNotStartGameEnabled"] == 1 and plan["skippedAlreadyEnabledInMaster"] == 1, plan
    fixed = [int(x["fixedFormId"], 16) for x in plan["eligible"]]
    loaded = [int(x["formId"], 16) for x in plan["eligible"]]
    assert fixed == EXPECTED and loaded != fixed, plan
    assert not output.exists()
    applied = client.call("exports.seq", **args, dryRun=False)
    assert applied["complete"] and applied["written"] and applied["changed"], applied
    assert_output(output)
    refused = client.request(json.dumps({"command": "exports.seq", "args": {**args, "dryRun": False}}))
    assert not refused["ok"] and refused["error"]["code"] == "state_conflict", refused
    assert_output(output)
    overwritten = client.call("exports.seq", **args, dryRun=False, overwrite=True)
    assert overwritten["written"] and overwritten["complete"], overwritten
    assert_output(output)
    dummy_path = (directory / Path(DUMMY).with_suffix(".seq")).resolve()
    unchanged = dummy_path.read_bytes()
    skipped = client.call("exports.seq", file=DUMMY, outputPath=str(dummy_path), dryRun=False)
    assert skipped["skipReason"] == "no-eligible-quests" and not skipped["written"] and skipped["existingOutputRetained"], skipped
    assert dummy_path.read_bytes() == unchanged
    zero = client.call("exports.seq", file="Skyrim.esm", outputPath=str((directory / "Skyrim.seq").resolve()), dryRun=False)
    assert zero["skipReason"] == "load-order-zero" and not zero["written"], zero
    after = client.call("session.get_dirty_state")
    assert before["mutationRevision"] == after["mutationRevision"] and before["dirtyFiles"] == after["dirtyFiles"]


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("generate", "exercise", "verify"))
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    directory = args.overlay / "Seq"
    if args.phase == "generate":
        directory.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures().items():
            with (args.overlay / name).open("xb") as stream: stream.write(data)
        with (directory / Path(DUMMY).with_suffix(".seq")).open("xb") as stream:
            stream.write(b"existing-empty-scene-output")
    elif args.phase == "verify":
        assert_output(directory / Path(PATCH).with_suffix(".seq"))
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Exercise requires --exe, --pid and --artifacts")
        exercise(Client(args.exe, args.pid, args.artifacts), directory)


if __name__ == "__main__": main()
