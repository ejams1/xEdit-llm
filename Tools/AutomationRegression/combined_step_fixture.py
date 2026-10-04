"""Full-file FO4 cleaning, preorder retention and phase cancellation acceptance.

Generate into a fresh MO2 overlay. Exercise with a consent-enabled native daemon,
then relaunch for verify. Python tests validate fixture bytes and assertions only.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord, read_keywords
from report_fixture import signatures
from selective_step_fixture import group, records, object_id, start
from validation_step_fixture import findings

MASTER = "AutomationCombinedStepBase.esm"
UNUSED = "AutomationCombinedStepUnused.esm"
QUICK = "AutomationCombinedStepQuick.esp"
AUTO = "AutomationCombinedStepAuto.esp"
CANCEL = "AutomationCombinedStepCancel.esp"
SORT = "AutomationCombinedStepSort.esp"
KEYWORDS = 1400
REFERENCES = 600
CELL_ID = 0x01003000
PARENT_ID = 0x01004000
CHILD_ID = 0x01003800  # Sorting roots by FormID would reverse native preorder.
NAVM_ID = 0x01002800
QUICK_KIND = "cleaning.quick_clean"
AUTO_KIND = "cleaning.quick_auto_clean"
SORT_KIND = "cleaning.sort_and_clean_masters"


def header(masters, count, esm=False):
    body = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0x5000))
    for master in masters:
        body += subrecord(b"MAST", master.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    return record(b"TES4", body, int(esm))


def fixtures():
    keywords, overrides = [], []
    for index in range(KEYWORDS):
        body = subrecord(b"EDID", f"CombinedStepKeyword{index:04d}".encode() + b"\0")
        identity = 0x01000800 + index
        keywords.append(record(b"KYWD", body, form_id=identity))
        overrides.append(record(b"KYWD", body, 0x80000000 if index % 2 else 0, identity))
    static = subrecord(b"EDID", b"CombinedStepStatic\0")
    static += subrecord(b"OBND", b"\0" * 12) + subrecord(b"MODL", b"automation\\combined.nif\0")
    static = group(b"STAT", 0, record(b"STAT", static, form_id=0x01001000))

    def reference(identity, name, deleted=False):
        body = subrecord(b"EDID", name.encode() + b"\0")
        body += subrecord(b"NAME", struct.pack("<I", 0x01001000))
        body += subrecord(b"DATA", struct.pack("<6f", 100, 200, 300, 0, 0, 0))
        return record(b"REFR", body, 0x20 if deleted else 0, identity)

    def interior(identity, name, children):
        cell = record(b"CELL", subrecord(b"EDID", name.encode() + b"\0") +
                      subrecord(b"DATA", b"\1\0"), form_id=identity)
        children = group(identity, 6, group(identity, 9, children))
        object_id = identity & 0xFFFFFF
        return group(object_id % 10, 2, group(object_id // 10 % 10, 3, cell + children))

    def cells(deleted, control=True):
        refs = b"".join(reference(0x01002000 + i, f"CombinedStepRef{i:04d}", deleted)
                        for i in range(REFERENCES))
        refs += record(b"NAVM", b"", 0x20 if deleted else 0, NAVM_ID)
        body = interior(CELL_ID, "CombinedStepInterior", refs)
        if control:
            body += interior(PARENT_ID, "CombinedStepParent", reference(CHILD_ID, "CombinedStepChild"))
        return group(b"CELL", 0, body)

    base_count = KEYWORDS + REFERENCES + 5  # STAT, two CELLs, NAVM, control REFR.
    base = header(["Fallout4.esm"], base_count, True)
    base += group(b"KYWD", 0, b"".join(keywords)) + static + cells(False)
    result = {MASTER: base, UNUSED: header(["Fallout4.esm"], 0, True)}
    for name, control, unused in ((QUICK, True, False), (AUTO, True, True), (CANCEL, False, False)):
        masters = ["Fallout4.esm", MASTER] + ([UNUSED] if unused else [])
        count = KEYWORDS + REFERENCES + 2 + (2 if control else 0)
        result[name] = header(masters, count) + group(b"KYWD", 0, b"".join(overrides)) + cells(True, control)
    result[SORT] = header(["Fallout4.esm", MASTER, UNUSED], 1) + group(b"KYWD", 0, overrides[1])
    return result


def validate_state(state):
    progress, detail = state["progress"], state["progress"]["detail"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["lastMutations"] <= detail["mutationLimit"] == 16, state
    assert not detail["nativeCallsPreemptible"] and detail["softBudgetMs"] == 20, state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert 0 <= progress["completed"] <= progress["total"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    assert 0 <= detail["processedRecords"] <= detail["collectedRecords"], state
    assert detail["retainedRecords"] == detail["collectedRecords"] - detail["processedRecords"], state
    rows = state["result"].get("files", [])
    for row in rows:
        assert 0 <= row["applied"] <= row["planned"], row
        assert not row["complete"] or row["workComplete"], row
        if row["operation"] == "sort_and_clean_masters":
            operations = list(row["operations"].values())
            for field in ("planned", "applied", "skipped"):
                assert row[field] == sum(op[field] for op in operations), row
            assert not row["workComplete"] or all(op["complete"] for op in operations), row
        if state["dryRun"]:
            assert not row["applied"] and not row["mutationState"]["mutationsObserved"], row
    for field in ("planned", "applied", "skipped"):
        assert state["summary"][field] == sum(row[field] for row in rows), state
    if state["dryRun"]:
        assert not detail["lastMutations"], state
    if state["terminal"]:
        assert not state["cursorRetained"], state
    if state["state"] == "succeeded":
        assert progress["remaining"] == 0 and rows and all(row["complete"] for row in rows), state


def poll_until(client, job_id, predicate, timings):
    for _ in range(10000):
        started = time.monotonic()
        state = client.call("jobs.get", jobId=job_id)
        timings.append(time.monotonic() - started)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("Combined cleaning did not reach the requested boundary in 10000 polls")


def assert_loaded(client, file, removed, cleaned_refs=0, control=False):
    observed = {object_id(entry["locator"]) for entry in records(client, file, "KYWD")}
    assert observed == set(range(0x800, 0x800 + KEYWORDS)) - removed, observed
    refs = records(client, file, "REFR")
    assert {object_id(entry["locator"]) for entry in refs} == set(range(0x2000, 0x2000 + REFERENCES)), refs
    assert sum(not entry["object"]["isDeleted"] for entry in refs) == cleaned_refs, refs
    for entry in refs:
        if entry["object"]["isDeleted"]:
            continue
        flags = client.call("elements.get_value", **{**entry["locator"], "path": r"Record Header\Record Flags"})
        flags = int(flags["values"]["nativeValue"]["value"])
        assert flags & 0x800 and not flags & 0x20, flags
    navmesh = records(client, file, "NAVM")
    assert len(navmesh) == 1 and navmesh[0]["object"]["isDeleted"], navmesh
    expected_cells = {CELL_ID & 0xFFFFFF} | ({PARENT_ID & 0xFFFFFF} if control else set())
    assert {object_id(entry["locator"]) for entry in records(client, file, "CELL")} == expected_cells


def cancel(client, job_id, partial):
    retained = findings(client, job_id)
    canceled = client.call("jobs.cancel", jobId=job_id)
    validate_state(canceled)
    assert canceled["state"] == "canceled" and canceled["progress"] == partial["progress"], canceled
    assert findings(client, job_id) == retained
    assert client.call("jobs.get", jobId=job_id) == canceled
    client.call("jobs.discard", jobId=job_id)
    return canceled


def exercise(client, overlay, artifacts):
    baseline = client.call("session.get_dirty_state")
    assert not baseline["dirty"] and not baseline["pendingShutdownCount"], baseline
    timings, snapshots = [], []
    job_id = start(client, QUICK_KIND, CANCEL)  # Omitted dryRun must stay read-only.
    partial = poll_until(client, job_id, lambda s: s["progress"]["detail"]["phase"] == "collect-itm" and
                         s["progress"]["detail"]["collectedRecords"] > 0, timings)
    assert partial["dryRun"] and not partial["summary"]["planned"], partial
    snapshots.append(cancel(client, job_id, partial))
    assert client.call("session.get_dirty_state") == baseline

    job_id = start(client, QUICK_KIND, CANCEL, False)
    ready = poll_until(client, job_id, lambda s: s["progress"]["detail"]["phase"] == "itm", timings)
    assert ready["progress"]["detail"]["collectedRecords"] > 1000 and not ready["summary"]["applied"], ready
    partial = poll_until(client, job_id, lambda s: s["summary"]["applied"] > 0, timings)
    removed = set(range(0x800, 0x800 + KEYWORDS)) - {
        object_id(entry["locator"]) for entry in records(client, CANCEL, "KYWD")}
    assert 0 < len(removed) == partial["summary"]["applied"] <= 16, partial
    assert all((identity - 0x800) % 2 == 0 for identity in removed), removed
    assert not partial["terminal"] and partial["progress"]["completed"] == 0, partial
    denied = client.request(json.dumps({"command": "session.save", "args": {"files": [CANCEL]}}))
    assert denied["error"]["code"] == "job_busy", denied
    canceled = cancel(client, job_id, partial)
    assert canceled["summary"]["partialChanges"] and canceled["summary"]["requiresSave"], canceled
    assert canceled["result"]["files"][0]["mutationState"]["mutationsObserved"], canceled
    snapshots.append(canceled)
    assert_loaded(client, CANCEL, removed)

    # Complete ITM, then cancel during a fresh UDR collection. Earlier findings survive.
    job_id = start(client, QUICK_KIND, CANCEL, False)
    partial = poll_until(client, job_id, lambda s: s["progress"]["detail"]["phase"] == "collect-udr" and
                         s["progress"]["detail"]["collectedRecords"] > 0, timings)
    assert partial["result"]["files"][0]["complete"] and not partial["result"]["files"][1]["complete"], partial
    assert len(findings(client, job_id)) == 1
    snapshots.append(cancel(client, job_id, partial))

    # Sort and CleanMasters are distinct native units even on a small file.
    job_id = start(client, SORT_KIND, SORT, False)
    partial = poll_until(client, job_id, lambda s: s["progress"]["detail"]["phase"] == "clean-masters", timings)
    row = partial["result"]["files"][0]
    assert row["operations"]["sort"]["complete"] and not row["operations"]["cleanMasters"]["complete"], row
    assert UNUSED in client.call("files.get", name=SORT)["file"]["masters"]
    snapshots.append(cancel(client, job_id, partial))
    job_id = start(client, SORT_KIND, SORT, False)
    done = poll_until(client, job_id, lambda s: s["terminal"], timings)
    assert done["state"] == "succeeded" and done["summary"]["planned"] == 2, done
    assert done["result"]["files"][0]["operations"]["cleanMasters"]["applied"] == 1, done
    assert client.call("files.get", name=SORT)["file"]["masters"] == ["Fallout4.esm", MASTER]
    snapshots.append(done)
    client.call("jobs.discard", jobId=job_id)

    expected = {0x800 + i for i in range(KEYWORDS) if i % 2 == 0}
    for file, kind, control in ((CANCEL, QUICK_KIND, False), (QUICK, QUICK_KIND, True), (AUTO, AUTO_KIND, True)):
        before = client.call("session.get_dirty_state")
        dry_id = start(client, kind, file, True)
        dry = poll_until(client, dry_id, lambda s: s["terminal"], timings)
        assert dry["state"] == "succeeded" and not dry["summary"]["applied"], dry
        assert client.call("session.get_dirty_state") == before
        client.call("jobs.discard", jobId=dry_id)
        job_id = start(client, kind, file, False)
        done = poll_until(client, job_id, lambda s: s["terminal"], timings)
        assert done["state"] == "succeeded", done
        rows = {row["operation"]: row for row in done["result"]["files"]}
        assert rows["remove_itm"]["applied"] == (KEYWORDS // 2 + 1 if control else 0), done
        assert rows["undelete_and_disable_refs"]["applied"] == REFERENCES, done
        admitted = findings(client, job_id)
        assert len(admitted) == (4 if kind == AUTO_KIND else 3), admitted
        assert_loaded(client, file, expected, REFERENCES, control)
        assert client.call("files.get", name=file)["file"]["masters"] == ["Fallout4.esm", MASTER]
        snapshots.append(done)
        client.call("jobs.discard", jobId=job_id)
    for file, blob in fixtures().items():
        assert (overlay / file).read_bytes() == blob, file
    report = {"jobs": snapshots, "pollSeconds": timings, "maxPollSeconds": max(timings),
              "timingIncludesClientProcessAndIPC": True, "hardLatencyGuaranteeTested": False}
    (artifacts / "combined-steps.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    client.call("session.save", files=[QUICK, AUTO, CANCEL, SORT])
    client.call("session.flush")


def verify(client, overlay):
    expected = {0x800 + i for i in range(KEYWORDS) if i % 2 == 0}
    for file in (QUICK, AUTO, CANCEL):
        assert_loaded(client, file, expected, REFERENCES, file != CANCEL)
        keywords = read_keywords((overlay / file).read_bytes())
        assert set(keywords) == {f"CombinedStepKeyword{i:04d}" for i in range(KEYWORDS) if i % 2}
        assert all(flags == 0x80000000 for _, flags in keywords.values()), keywords
        saved = signatures((overlay / file).read_bytes(), 24)
        refs = {identity: flags for sig, identity, flags in saved if sig == b"REFR"}
        assert set(refs) == set(range(0x2000, 0x2000 + REFERENCES)), refs
        assert all(flags & 0x800 and not flags & 0x20 for flags in refs.values()), refs
        assert (b"NAVM", NAVM_ID & 0xFFFFFF, 0x20) in saved
        if file != CANCEL:
            assert (b"CELL", PARENT_ID & 0xFFFFFF, 0) in saved
        assert client.call("files.get", name=file)["file"]["masters"] == ["Fallout4.esm", MASTER]
    assert client.call("files.get", name=SORT)["file"]["masters"] == ["Fallout4.esm", MASTER]
    for file in (MASTER, UNUSED):
        assert (overlay / file).read_bytes() == fixtures()[file], file


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
