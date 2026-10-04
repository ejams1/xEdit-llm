"""Within-file plan/apply cancellation and persistence for FO4 selective cleaning.

Generate only into a fresh MO2 overlay. Exercise with a consent-enabled daemon,
then relaunch a fresh process for verify. Python integrity tests are not native
Delphi/runtime evidence.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord, read_keywords
from pagination_fixture import drain
from report_fixture import signatures
from validation_step_fixture import findings

MASTER = "AutomationSelectiveStepBase.esm"
ITM = "AutomationSelectiveStepITM.esp"
UDR = "AutomationSelectiveStepUDR.esp"
COUNT = 400
ITM_KIND = "cleaning.remove_itm"
UDR_KIND = "cleaning.undelete_and_disable_refs"
CELL_ID = 0x01001010
NAVM_ID = 0x01002200


def group(label, kind, body):
    if isinstance(label, int):
        label = struct.pack("<I", label)
    return struct.pack("<4sI4sIHHHH", b"GRUP", 24 + len(body), label, kind, 0, 0, 0, 0) + body


def header(masters, count, esm=False):
    body = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0x3000))
    for master in masters:
        body += subrecord(b"MAST", master.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    return record(b"TES4", body, flags=int(esm))


def fixtures():
    keywords, overrides = [], []
    for index in range(COUNT):
        body = subrecord(b"EDID", f"SelectiveStepKeyword{index:04d}".encode() + b"\0")
        identity = 0x01000800 + index
        keywords.append(record(b"KYWD", body, form_id=identity))
        overrides.append(record(b"KYWD", body, 0 if index % 2 == 0 else 0x80000000, identity))
    static = subrecord(b"EDID", b"SelectiveStepStatic\0")
    static += subrecord(b"OBND", b"\0" * 12) + subrecord(b"MODL", b"automation\\step.nif\0")
    static = group(b"STAT", 0, record(b"STAT", static, form_id=0x01001000))
    cell = record(b"CELL", subrecord(b"EDID", b"SelectiveStepInterior\0") +
                  subrecord(b"DATA", b"\1\0"), form_id=CELL_ID)

    def cells(deleted):
        refs = []
        for index in range(COUNT):
            body = subrecord(b"EDID", f"SelectiveStepRef{index:04d}".encode() + b"\0")
            body += subrecord(b"NAME", struct.pack("<I", 0x01001000))
            body += subrecord(b"DATA", struct.pack("<6f", 100, 200, 300, 0, 0, 0))
            refs.append(record(b"REFR", body, 0x20 if deleted else 0, 0x01002000 + index))
        refs.append(record(b"NAVM", b"", 0x20 if deleted else 0, NAVM_ID))
        children = group(CELL_ID, 6, group(CELL_ID, 9, b"".join(refs)))
        # Native interior grouping uses the last two decimal object-ID digits.
        object_id = CELL_ID & 0xFFFFFF
        return group(b"CELL", 0, group(object_id % 10, 2,
                     group(object_id // 10 % 10, 3, cell + children)))

    return {
        MASTER: header(["Fallout4.esm"], COUNT * 2 + 3, True) +
                group(b"KYWD", 0, b"".join(keywords)) + static + cells(False),
        ITM: header(["Fallout4.esm", MASTER], COUNT) + group(b"KYWD", 0, b"".join(overrides)),
        UDR: header(["Fallout4.esm", MASTER], COUNT + 2) + cells(True),
    }


def validate_state(state):
    progress, detail = state["progress"], state["progress"]["detail"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["lastMutations"] <= detail["mutationLimit"] == 16, state
    assert not detail["nativeCallsPreemptible"] and detail["softBudgetMs"] == 20, state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert 0 <= progress["completed"] <= progress["total"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    rows = state["result"]["files"]
    for file in rows:
        records = file["records"]
        applied = sum(row["outcome"] == "applied" for row in records)
        eligible = sum(row["outcome"] != "skipped" for row in records)
        assert file["applied"] == applied and file["planned"] == eligible, file
        assert file["skipped"] == sum(row["outcome"] == "skipped" for row in records), file
        assert len({row["locator"]["formId"] for row in records}) == len(records), file
        if not file["planningComplete"]:
            assert not applied, file
        if state["dryRun"]:
            assert not applied and not detail["lastMutations"], state
        if file["complete"]:
            assert file["planningComplete"], file
            if not state["dryRun"]:
                assert applied == file["planned"], file
    assert state["summary"]["applied"] == sum(file["applied"] for file in rows), state
    if state["terminal"]:
        assert not state["cursorRetained"], state
    if state["state"] == "succeeded":
        assert progress["remaining"] == 0 and all(file["complete"] for file in rows), state


def poll_until(client, job_id, predicate, timings):
    for _ in range(10000):
        started = time.monotonic()
        state = client.call("jobs.get", jobId=job_id)
        timings.append(time.monotonic() - started)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("Selective job did not reach the requested boundary in 10000 polls")


def start(client, kind, file, dry=None):
    args = {"kind": kind, "target": {"files": [file]}}
    if dry is not None:
        args["dryRun"] = dry
    return client.call("jobs.start", **args)["jobId"]


def records(client, file, signature):
    return drain(client, "records.list", "records", {"file": file, "signature": signature, "limit": 500})[0]


def object_id(locator):
    return int(locator["formId"].replace(" ", ""), 16) & 0xFFFFFF


def applied_ids(state):
    return {object_id(row["locator"]) for row in state["result"]["files"][0]["records"]
            if row["outcome"] == "applied"}


def assert_loaded(client, file, applied):
    if file == ITM:
        observed = {object_id(entry["locator"]) for entry in records(client, file, "KYWD")}
        assert observed == set(range(0x800, 0x800 + COUNT)) - applied, observed
    else:
        observed = {object_id(entry["locator"]): entry["object"]["isDeleted"]
                    for entry in records(client, file, "REFR")}
        assert set(observed) == set(range(0x2000, 0x2000 + COUNT)), observed
        assert {identity for identity, deleted in observed.items() if not deleted} == applied, observed
        for entry in records(client, file, "REFR"):
            if object_id(entry["locator"]) not in applied:
                continue
            flags = client.call("elements.get_value", **{**entry["locator"], "path": r"Record Header\Record Flags"})
            flags = int(flags["values"]["nativeValue"]["value"])
            assert flags & 0x800 and not flags & 0x20, flags
        navm = records(client, file, "NAVM")
        assert len(navm) == 1 and navm[0]["object"]["isDeleted"], navm
        assert len(records(client, file, "CELL")) == 1


def exercise(client, overlay, artifacts):
    baseline = client.call("session.get_dirty_state")
    assert not baseline["dirty"] and not baseline["pendingShutdownCount"], baseline
    timings, completed = [], []
    for kind, file, eligible in ((ITM_KIND, ITM, COUNT // 2), (UDR_KIND, UDR, COUNT)):
        before = client.call("session.get_dirty_state")
        # Omitted dryRun must remain read-only through partial classification.
        job_id = start(client, kind, file)
        partial = poll_until(client, job_id, lambda s: s["progress"]["detail"]["phase"] == "planning" and
                             0 < s["summary"]["planned"] < eligible, timings)
        retained = findings(client, job_id)
        canceled = client.call("jobs.cancel", jobId=job_id)
        validate_state(canceled)
        assert canceled["state"] == "canceled" and canceled["progress"] == partial["progress"], canceled
        assert findings(client, job_id) == retained
        assert client.call("session.get_dirty_state") == before
        client.call("jobs.discard", jobId=job_id)
        planned_id = start(client, kind, file, True)
        planned = poll_until(client, planned_id, lambda s: s["terminal"], timings)
        assert planned["state"] == "succeeded" and planned["summary"]["planned"] == eligible, planned
        assert findings(client, planned_id)[:len(retained)] == retained
        assert client.call("session.get_dirty_state") == before
        client.call("jobs.discard", jobId=planned_id)

        # A finished planning snapshot must be observable before any writes.
        apply_id = start(client, kind, file, False)
        ready = poll_until(client, apply_id, lambda s: s["progress"]["detail"]["planningComplete"], timings)
        assert ready["summary"]["applied"] == 0 and client.call("session.get_dirty_state") == before, ready
        assert_loaded(client, file, set())
        partial = poll_until(client, apply_id, lambda s: s["summary"]["applied"] > 0, timings)
        applied = applied_ids(partial)
        assert 0 < len(applied) <= 16 < eligible, partial
        assert not partial["terminal"] and partial["progress"]["completed"] == 0, partial
        assert_loaded(client, file, applied)
        retained = findings(client, apply_id)
        denied = client.request(json.dumps({"command": "session.save", "args": {"files": [file]}}))
        assert denied["error"]["code"] == "job_busy", denied
        canceled = client.call("jobs.cancel", jobId=apply_id)
        validate_state(canceled)
        assert canceled["state"] == "canceled" and canceled["progress"] == partial["progress"], canceled
        assert canceled["summary"]["partialChanges"] and canceled["summary"]["requiresSave"], canceled
        assert findings(client, apply_id) == retained
        assert client.call("jobs.get", jobId=apply_id) == canceled
        assert_loaded(client, file, applied)
        client.call("jobs.discard", jobId=apply_id)

        resumed_id = start(client, kind, file, False)
        resumed = poll_until(client, resumed_id, lambda s: s["terminal"], timings)
        assert resumed["state"] == "succeeded", resumed
        assert resumed["summary"]["planned"] == resumed["summary"]["applied"] == eligible - len(applied), resumed
        expected = ({0x800 + index for index in range(COUNT) if index % 2 == 0} if kind == ITM_KIND
                    else set(range(0x2000, 0x2000 + COUNT)))
        assert applied | applied_ids(resumed) == expected, resumed
        assert not applied & applied_ids(resumed), resumed
        assert_loaded(client, file, expected)
        assert client.call("files.get", name=file)["file"]["masters"] == ["Fallout4.esm", MASTER]
        completed.extend((canceled, resumed))
        client.call("jobs.discard", jobId=resumed_id)
    for file, blob in fixtures().items():
        assert (overlay / file).read_bytes() == blob, file
    report = {"jobs": completed, "pollSeconds": timings, "maxPollSeconds": max(timings),
              "timingIncludesClientProcessAndIPC": True, "hardLatencyGuaranteeTested": False}
    (artifacts / "selective-steps.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    client.call("session.save", files=[ITM, UDR])
    client.call("session.flush")


def verify(client, overlay):
    assert_loaded(client, ITM, {0x800 + index for index in range(COUNT) if index % 2 == 0})
    assert_loaded(client, UDR, set(range(0x2000, 0x2000 + COUNT)))
    keywords = read_keywords((overlay / ITM).read_bytes())
    assert set(keywords) == {f"SelectiveStepKeyword{i:04d}" for i in range(COUNT) if i % 2}
    assert all(flags == 0x80000000 for _, flags in keywords.values()), keywords
    saved = {identity: flags for sig, identity, flags in signatures((overlay / UDR).read_bytes(), 24) if sig == b"REFR"}
    assert set(saved) == set(range(0x2000, 0x2000 + COUNT))
    assert all(flags & 0x800 and not flags & 0x20 for flags in saved.values()), saved
    assert (b"NAVM", NAVM_ID & 0xFFFFFF, 0x20) in signatures((overlay / UDR).read_bytes(), 24)


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("generate", "exercise", "verify"))
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        args.overlay.mkdir(parents=True, exist_ok=True)
        for file, blob in fixtures().items():
            with (args.overlay / file).open("xb") as stream:
                stream.write(blob)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Live phases require --exe, --pid and --artifacts")
        client = Client(args.exe, args.pid, args.artifacts)
        if args.phase == "exercise":
            exercise(client, args.overlay, args.artifacts)
        else:
            verify(client, args.overlay)


if __name__ == "__main__":
    main()
