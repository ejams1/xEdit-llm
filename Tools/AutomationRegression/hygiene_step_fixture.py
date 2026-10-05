"""FO4 retained master scan, cancellation, direct-native parity and restart acceptance.

Generate into a fresh dedicated MO2 overlay. Load Fallout4.esm followed by
BASE, LABEL, UNUSED, STEPPED, DIRECT, CANCELED in that order. Exercise needs
consent and edit mode; verify needs a fresh process after save/terminal flush.
Python integrity tests do not execute native xEdit.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord
from row_fixture import disk_state, form_list, keyword
from selective_step_fixture import group, records
from validation_step_fixture import findings

BASE = "AutomationHygieneBase.esm"
LABEL = "AutomationHygieneLabel.esm"
UNUSED = "AutomationHygieneUnused.esm"
STEPPED = "AutomationHygieneStepped.esp"
DIRECT = "AutomationHygieneDirect.esp"
CANCELED = "AutomationHygieneCanceled.esp"
COUNT = 2200
KIND = "files.hygiene.batch"
INITIAL = ["Fallout4.esm", BASE, LABEL, UNUSED]
FINAL = INITIAL[:-1]


def plugin(masters, groups, count, esm=False):
    body = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0x8000))
    for name in masters:
        body += subrecord(b"MAST", name.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    return record(b"TES4", body, int(esm)) + b"".join(groups)


def raw_headers(blob):
    """Decode record slots and group labels without daemon projection/ID masking."""
    rows, groups = [], []

    def visit(start, stop):
        while start < stop:
            sig, size = struct.unpack_from("<4sI", blob, start)
            if sig == b"GRUP":
                label, kind = struct.unpack_from("<II", blob, start + 8)
                groups.append((kind, label))
                visit(start + 24, start + size)
                start += size
            else:
                rows.append((sig, struct.unpack_from("<I", blob, start + 12)[0]))
                start += 24 + size
        assert start == stop

    visit(0, len(blob))
    return rows, groups


def fixtures():
    keywords = b"".join(keyword(f"HygieneKeyword{i:04d}", 0x01000800 + i) for i in range(COUNT))
    cell = record(b"CELL", subrecord(b"EDID", b"HygieneLabelOnlyCell\0") +
                  subrecord(b"DATA", b"\1\0"), form_id=0x01007000)
    label_cells = group(b"CELL", 0, group(2, 2, group(7, 3, cell)))
    result = {
        BASE: plugin(["Fallout4.esm"], [group(b"KYWD", 0, keywords)], COUNT, True),
        LABEL: plugin(["Fallout4.esm"], [label_cells], 1, True),
        UNUSED: plugin(["Fallout4.esm"], [], 0, True),
    }
    # No record/payload references LABEL: only EMPTY type-6/9 group labels use
    # its CELL. A flat file.Records scan would wrongly remove this dependency.
    empty_groups = group(b"CELL", 0, group(2, 2, group(7, 3,
                       group(0x02007000, 6, group(0x02007000, 9, b"")))))
    payload = form_list("HygieneOwnList", 0x04006000, [0x01000800, 0x01001097])
    for name in (STEPPED, DIRECT, CANCELED):
        result[name] = plugin(INITIAL, [group(b"KYWD", 0, keywords),
                             group(b"FLST", 0, payload), empty_groups], COUNT + 1)
    return result


def validate_state(state):
    detail, progress = state["progress"]["detail"], state["progress"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["lastMutations"] <= detail["mutationLimit"] == 1, state
    assert 0 <= detail["scanWorkUnits"] <= detail["scanWorkLimit"] == 1000000, state
    assert 0 <= detail["retainedDepth"] <= detail["depthLimit"] == 128, state
    assert not detail["nativeCallsPreemptible"] and detail["softBudgetMs"] == 20, state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert 0 <= progress["completed"] <= progress["total"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    rows = state["result"]["files"]
    for field in ("planned", "applied", "skipped"):
        assert state["summary"].get(field, 0) == sum(row.get(field, 0) for row in rows), state
    for row in rows:
        assert not row["complete"] or all(op["complete"] for op in row["operations"]), row
        if state["dryRun"]:
            assert not row.get("applied", 0) and not row["mutationState"]["mutationsObserved"], row
    if state["terminal"]:
        assert not state["cursorRetained"], state
    if state["state"] == "succeeded":
        assert progress["remaining"] == 0 and all(row["complete"] for row in rows), state


def start(client, files, dry=None, operations=("sort_masters", "clean_masters")):
    args = {"kind": KIND, "target": {"files": files}, "options": {"operations": list(operations)}}
    if dry is not None:
        args["dryRun"] = dry
    return client.call("jobs.start", **args)["jobId"]


def poll(client, job_id, predicate, timings):
    for _ in range(20000):
        began = time.monotonic()
        state = client.call("jobs.get", jobId=job_id)
        timings.append(time.monotonic() - began)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("Master hygiene did not reach requested boundary")


def cancel(client, job_id, partial):
    events = findings(client, job_id)
    state = client.call("jobs.cancel", jobId=job_id)
    validate_state(state)
    assert state["state"] == "canceled" and state["progress"] == partial["progress"], state
    assert state["result"] == partial["result"] and findings(client, job_id) == events, state
    assert client.call("jobs.get", jobId=job_id) == state
    client.call("jobs.discard", jobId=job_id)
    return state


def masters(client, name):
    return client.call("files.get", name=name)["file"]["masters"]


def assert_loaded(client, file, expected):
    assert masters(client, file) == expected
    assert len(records(client, file, "KYWD")) == COUNT
    lists = records(client, file, "FLST")
    assert len(lists) == 1 and lists[0]["object"]["editorId"] == "HygieneOwnList", lists
    links = client.call("records.references", **lists[0]["locator"])
    assert links["complete"] and len(links["hits"]) == 2, links
    assert {hit["object"]["editorId"] for hit in links["hits"]} == {
        "HygieneKeyword0000", "HygieneKeyword2199"}, links


def exercise(client, overlay, artifacts):
    initial = client.call("session.get_dirty_state")
    assert not initial["dirty"], initial
    before = {name: (overlay / name).read_bytes() for name in fixtures()}
    timings, snapshots = [], []
    # Every target is resolved at start; a bad later target leaves earlier ones untouched.
    for files in ([STEPPED, "Missing.esp"], [STEPPED, STEPPED], [], [STEPPED] * 257):
        reply = client.request(json.dumps({"command": "jobs.start", "args": {
            "kind": KIND, "dryRun": False, "target": {"files": files},
            "options": {"operations": ["clean_masters"]}}}))
        assert not reply["ok"], reply
    assert client.call("session.get_dirty_state") == initial
    job_id = start(client, [STEPPED], operations=("clean_masters", "sort_masters", "sort_masters"))
    dry = poll(client, job_id, lambda s: s["terminal"], timings)
    assert dry["state"] == "succeeded" and dry["dryRun"], dry
    assert [op["operation"] for op in dry["result"]["files"][0]["operations"]] == [
        "sort_masters", "clean_masters"], dry
    snapshots.append(dry)
    assert client.call("session.get_dirty_state") == initial
    # Cancellation DURING scanning, then AGAIN after scan before remapping.
    for boundary in (lambda s: s["progress"]["detail"]["phase"] == "scan-masters" and
                     s["progress"]["detail"]["nativeUsageCalls"] > 0,
                     lambda s: s["progress"]["detail"]["phase"] == "apply-clean-masters"):
        job_id = start(client, [CANCELED], False, ("clean_masters",))
        partial = poll(client, job_id, boundary, timings)
        assert not partial["terminal"] and not partial["summary"].get("changed", False), partial
        denied = client.request(json.dumps({"command": "session.save", "args": {"files": [CANCELED]}}))
        assert denied["error"]["code"] == "job_busy", denied
        snapshots.append(cancel(client, job_id, partial))
        assert client.call("session.get_dirty_state") == initial
        assert_loaded(client, CANCELED, INITIAL)
    # One file complete; cancellation leaves second file untouched and preserves events.
    job_id = start(client, [STEPPED, CANCELED], False)
    first = poll(client, job_id, lambda s: s["progress"]["completed"] == 1, timings)
    assert first["summary"]["changed"] and first["summary"]["requiresSave"], first
    snapshots.append(cancel(client, job_id, first))
    assert_loaded(client, STEPPED, FINAL)
    assert_loaded(client, CANCELED, INITIAL)
    direct = client.call("files.clean_masters", file=DIRECT)
    assert direct["removedMasters"] == [UNUSED] and direct["changed"], direct
    assert_loaded(client, DIRECT, FINAL)
    # Retry completed file is idempotent; append finished direct-native parity evidence.
    job_id = start(client, [STEPPED], False)
    final = poll(client, job_id, lambda s: s["terminal"], timings)
    assert final["state"] == "succeeded" and not final["summary"].get("changed", False), final
    snapshots.append(final)
    assert all((overlay / name).read_bytes() == blob for name, blob in before.items())
    (artifacts / "hygiene-step-report.json").write_text(json.dumps({
        "snapshots": snapshots, "pollSeconds": timings, "direct": direct,
        "timingScope": "IPC plus native atoms; no strict latency or preemption claim"}, indent=2), encoding="utf-8")
    client.call("session.save", files=[STEPPED, DIRECT])
    client.call("session.flush")


def verify(client, overlay):
    original = fixtures()
    for name in (BASE, LABEL, UNUSED, CANCELED):
        assert (overlay / name).read_bytes() == original[name], name
    for name in (STEPPED, DIRECT):
        assert_loaded(client, name, FINAL)
        master_names, rows = disk_state((overlay / name).read_bytes())
        assert master_names == FINAL and len(rows) == COUNT + 1, (name, master_names, len(rows))
        own = rows["HygieneOwnList"]
        assert own["identity"] == 0x6000, own
        assert [identity for sig, identity in raw_headers((overlay / name).read_bytes())[0]
                if sig == b"FLST"] == [0x03006000]
        assert [struct.unpack("<I", value)[0] for value in own["fields"][b"LNAM"]] == [
            0x01000800, 0x01001097], own
    assert disk_state((overlay / STEPPED).read_bytes()) == disk_state((overlay / DIRECT).read_bytes())


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
        for name, blob in fixtures().items():
            with (args.overlay / name).open("xb") as output:
                output.write(blob)
    else:
        if not args.exe or not args.pid or not args.artifacts:
            parser.error("exercise/verify require --exe, --pid and --artifacts")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        client = Client(args.exe, args.pid, args.artifacts)
        if args.phase == "exercise":
            exercise(client, args.overlay, args.artifacts)
        else:
            verify(client, args.overlay)


if __name__ == "__main__":
    main()
