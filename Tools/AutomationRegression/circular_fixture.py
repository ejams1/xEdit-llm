"""Generate FO4 leveled-list cycles and exercise the native validation job."""
import argparse
from pathlib import Path
import struct
from itm_fixture import Client, record, subrecord
from validation_step_fixture import finish

PLUGIN = "AutomationCircularLists.esp"
SIGNATURES = (b"LVLI", b"LVLN", b"LVSP")


def leveled_record(signature, name, form_id, target_id=None):
    body = subrecord(b"EDID", name.encode("ascii") + b"\0")
    body += subrecord(b"OBND", b"\0" * 12)
    body += subrecord(b"LVLD", b"\0") + subrecord(b"LVLF", b"\0")
    body += subrecord(b"LLCT", bytes((1 if target_id else 0,)))
    if target_id:
        # FO4 wbLeveledListEntry: level, unused, FormID, count, chance, unused.
        body += subrecord(b"LVLO", struct.pack("<HHIHBB", 1, 0, target_id, 1, 0, 0))
    return record(signature, body, form_id=form_id)


def fixture_bytes():
    header = subrecord(b"HEDR", struct.pack("<fII", 1.0, 7, 0x900))
    header += subrecord(b"MAST", b"Fallout4.esm\0") + subrecord(b"DATA", b"\0" * 8)
    groups = b""
    for index, signature in enumerate(SIGNATURES):
        first = 0x01000800 + index * 2
        records = leveled_record(signature, f"AutoCycle{signature.decode()}A", first, first + 1)
        records += leveled_record(signature, f"AutoCycle{signature.decode()}B", first + 1, first)
        if signature == b"LVLI":
            records += leveled_record(b"LVLI", "AutoAcyclicLVLI", 0x01000806)
        groups += struct.pack("<4sI4sIHHHH", b"GRUP", len(records) + 24,
                              signature, 0, 0, 0, 0, 0) + records
    return record(b"TES4", header) + groups


def exercise(client):
    before = client.call("session.get_dirty_state")
    job = client.call("jobs.start", kind="validation.circular_leveled_lists",
                      target={"files": [PLUGIN]})
    assert job["dryRun"] and job["progress"]["total"] == 1, job
    job = finish(client, job["jobId"], [])
    assert job["state"] == "succeeded", job
    assert job["progress"]["completed"] == 1, job
    assert job["summary"]["cycleCount"] >= 3, job
    findings = client.call("jobs.findings", jobId=job["jobId"], limit=500)["findings"]
    cycles = [finding for finding in findings if finding["code"] == "circular_leveled_list"]
    assert {finding["target"]["signature"] for finding in cycles} == {
        "LVLI", "LVLN", "LVSP"}, cycles
    assert all(len(finding["cyclePathNames"]) >= 2 for finding in cycles), cycles
    after = client.call("session.get_dirty_state")
    assert after["dirtyFiles"] == before["dirtyFiles"], (before, after)
    assert after["mutationRevision"] == before["mutationRevision"], (before, after)
    client.call("jobs.discard", jobId=job["jobId"])


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("generate", "exercise"))
    parser.add_argument("--overlay", type=Path, required=True)
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
            parser.error("Live phase requires --exe, --pid and --artifacts")
        exercise(Client(args.exe, args.pid, args.artifacts))


if __name__ == "__main__":
    main()
