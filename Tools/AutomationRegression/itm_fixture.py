"""Synthetic FO4 ITM fixtures and semantic checks against an already running daemon.

Only generate into an MO2 mod overlay, never a game's physical Data directory.
The caller owns MO2 launch, executable provenance and fresh-process relaunch.
"""

import argparse
import json
from pathlib import Path
import struct
import subprocess

MASTER = "AutomationItmMaster.esm"
PLUGIN = "AutomationItmOverride.esp"
CASES = [
    ("AutomationItmIdentical", 0, False),
    ("AutomationItmPersistentFlag", 0x400, False),
    ("AutomationItmDisabledFlag", 0x800, False),
    ("AutomationItmUnknownFlag", 0x80000000, False),
    ("AutomationItmChangedPayload", 0, True),
]


def subrecord(signature, payload):
    return struct.pack("<4sH", signature, len(payload)) + payload


def record(signature, payload, flags=0, form_id=0):
    return struct.pack("<4sIIIIHH", signature, len(payload), flags, form_id, 0, 131, 0) + payload


def plugin(masters, records, esm=False, record_count=None, next_object_id=0x900):
    if record_count is None:
        record_count = len(CASES)
    header = subrecord(b"HEDR", struct.pack("<fII", 1.0, record_count, next_object_id))
    for master in masters:
        header += subrecord(b"MAST", master.encode("ascii") + b"\0")
        header += subrecord(b"DATA", b"\0" * 8)
    group = struct.pack("<4sI4sIHHHH", b"GRUP", len(records) + 24, b"KYWD", 0, 0, 0, 0, 0) + records
    return record(b"TES4", header, int(esm)) + group


def fixtures():
    left, right = b"", b""
    for index, (name, flags, changed) in enumerate(CASES, 0x800):
        payload = subrecord(b"EDID", name.encode("ascii") + b"\0")
        # Both files use index 1 for the fixture master, so ordinary identical
        # records exercise native equality without reference-rebasing ambiguity.
        left += record(b"KYWD", payload, form_id=0x01000000 + index)
        if changed:
            payload = subrecord(b"EDID", (name + "Edited").encode("ascii") + b"\0")
        right += record(b"KYWD", payload, flags, 0x01000000 + index)
    return {MASTER: plugin(["Fallout4.esm"], left, True),
            PLUGIN: plugin(["Fallout4.esm", MASTER], right)}


def read_keywords(data):
    """Read the persisted semantic state independently of the daemon envelope."""
    result = {}

    def visit(start, end):
        while start < end:
            signature, size = struct.unpack_from("<4sI", data, start)
            if signature == b"GRUP":
                visit(start + 24, start + size)
                start += size
                continue
            flags, form_id = struct.unpack_from("<II", data, start + 8)
            pos, stop = start + 24, start + 24 + size
            if signature == b"KYWD":
                while pos < stop:
                    sub, length = struct.unpack_from("<4sH", data, pos)
                    if sub == b"EDID":
                        result[data[pos + 6:pos + 6 + length].rstrip(b"\0").decode("ascii")] = (form_id, flags)
                    pos += 6 + length
            start = stop
        if start != end:
            raise ValueError("Malformed fixture record boundary")

    visit(0, len(data))
    return result


def expected_retained():
    return {name + ("Edited" if changed else ""): flags
            for name, flags, changed in CASES[1:]}


def check_disk(path):
    observed = read_keywords(path.read_bytes())
    expected = expected_retained()
    assert set(observed) == set(expected), (observed, expected)
    assert {name: flags for name, (_, flags) in observed.items()} == expected


class Client:
    def __init__(self, executable, pid, artifacts):
        self.executable, self.pid, self.artifacts = executable, pid, artifacts
        self.sequence = 0
        artifacts.mkdir(parents=True, exist_ok=True)

    def call(self, command, /, **args):
        envelope = self.request(json.dumps({"command": command, "args": args}))
        if not envelope.get("ok"):
            raise RuntimeError(envelope)
        return envelope["result"]

    def request(self, text):
        """Send exact text, including keys/correlation, and retain error envelopes."""
        self.sequence += 1
        stem = self.artifacts / f"{self.sequence:03d}-exchange"
        request = stem.with_suffix(".request.json")
        response = stem.with_suffix(".response.json")
        request.write_text(text, encoding="utf-8")
        completed = subprocess.run([
            str(self.executable), f"-automation-call-pid:{self.pid}",
            f"-automation-call-request:{request.resolve()}",
            f"-automation-call-response:{response.resolve()}",
        ], timeout=85, capture_output=True, text=True)
        if not response.exists():
            raise RuntimeError(f"No response: {completed.returncode}, {completed.stderr}")
        envelope = json.loads(response.read_text(encoding="utf-8-sig"))
        return envelope

    def job(self, kind, dry_run):
        job = self.call("jobs.start", kind=kind, dryRun=dry_run, target={"files": [PLUGIN]})
        for _ in range(100):
            job = self.call("jobs.get", jobId=job["jobId"])
            if job["terminal"]:
                assert job["state"] == "succeeded", job
                return job, self.call("jobs.findings", jobId=job["jobId"], limit=500)["findings"]
        raise RuntimeError("Job did not complete within 100 advances")


def check_live(client, phase):
    records = client.call("records.list", file=PLUGIN, signature="KYWD")
    assert not records["truncated"], records
    items = records["records"]
    names = {entry["object"]["editorId"] for entry in items}
    expected = set(expected_retained())
    if phase == "exercise":
        assert names == expected | {CASES[0][0]}, names
        ids = {entry["object"]["editorId"]: entry["object"]["formId"] for entry in items}
        _, findings = client.job("validation.check_for_itm", True)
        actual = {finding["target"]["formId"] for finding in findings if finding["code"] == "itm_record"}
        assert actual == {ids[CASES[0][0]]}, findings
        job, _ = client.job("cleaning.quick_clean", True)
        assert job["summary"]["planned"] == 1, job
        job, _ = client.job("cleaning.quick_clean", False)
        assert job["summary"]["applied"] == 1, job
        check_live(client, "verify")
        client.call("session.save", files=[PLUGIN])
        client.call("session.flush")
    else:
        assert names == expected, names
        _, findings = client.job("validation.check_for_itm", True)
        assert not any(f["code"] == "itm_record" for f in findings), findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["generate", "exercise", "verify", "disk"])
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        args.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures().items():
            destination = args.overlay / name
            with destination.open("xb") as stream:
                stream.write(data)
    elif args.phase == "disk":
        check_disk(args.overlay / PLUGIN)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Live phases require --exe, --pid and --artifacts")
        check_live(Client(args.exe, args.pid, args.artifacts), args.phase)


if __name__ == "__main__":
    main()
