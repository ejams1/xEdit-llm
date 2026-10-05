"""FO4 retained native container reference rebuild/cancel/owner-link acceptance.

Generate a fresh overlay; load Fallout4.esm, STEPPED, CANCELED in that order.
Exercise intentionally edits/restores one live link to stale each file index,
then rebuilds indexes without saving any plugin. Native execution is separate
from Python fixture/assertion integrity tests.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord
from row_fixture import keyword, form_list, children, at
from selective_step_fixture import group, records
from esl_step_fixture import plugin

STEPPED = "AutomationReferenceStepped.esp"
CANCELED = "AutomationReferenceCanceled.esp"
COUNT = 4000
KIND = "analysis.build_references"


def fixtures():
    keys = keyword("ReferenceKeyA", 0x01000800) + keyword("ReferenceKeyB", 0x01000801)
    lists = b"".join(form_list(f"ReferenceCaller{i:04d}", 0x01000A00 + i, [0x01000800]) for i in range(COUNT))
    cell = record(b"CELL", subrecord(b"EDID", b"ReferenceEmptyOwner\0") +
                  subrecord(b"DATA", b"\1\0"), form_id=0x01003000)
    cells = group(b"CELL", 0, group(8, 2, group(8, 3, cell +
                  group(0x01003000, 6, group(0x01003000, 9, b"")))))
    blob = plugin(["Fallout4.esm"], [group(b"KYWD", 0, keys), group(b"FLST", 0, lists), cells], COUNT + 3, 0x3001)
    return {STEPPED: blob, CANCELED: blob}


def validate_state(state):
    detail, progress = state["progress"]["detail"], state["progress"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["scanWorkUnits"] <= detail["scanWorkLimit"] == 1000000, state
    assert 0 <= detail["nativeUnits"] <= detail["scanWorkUnits"], state
    assert 0 <= detail["retainedDepth"] <= detail["depthLimit"] == 128, state
    assert detail["softBudgetMs"] == 20 and not detail["nativeCallsPreemptible"], state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    rows = state["result"]["steps"]
    assert sum(row["complete"] for row in rows) == progress["completed"], state
    assert state["summary"].get("indexedFiles", 0) == sum(
        row["phase"] == "references" and row["complete"] and row["outcome"] == "completed" for row in rows), state
    for row in rows:
        if not row["complete"]:
            assert not row.get("currentAfter", False), row
    if state["terminal"]:
        assert not state["cursorRetained"], state


def start(client, target, dry=None):
    args = {"kind": KIND, "target": target}
    if dry is not None:
        args["dryRun"] = dry
    return client.call("jobs.start", **args)["jobId"]


def poll(client, job, predicate, timings):
    for _ in range(20000):
        began = time.monotonic()
        state = client.call("jobs.get", jobId=job)
        timings.append(time.monotonic() - began)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("Reference rebuild did not reach requested boundary")


def stale_file(client, file):
    ids = {entry["object"]["editorId"]: entry["locator"] for sig in ("KYWD", "FLST", "CELL")
           for entry in records(client, file, sig)}
    leaf = children(client, at(ids["ReferenceCaller0000"], "FormIDs"))[0]
    old = client.call("elements.get_value", **leaf)["values"]["editValue"]
    client.call("elements.set_value", **{**leaf, "value": ids["ReferenceKeyB"]["formId"]})
    client.call("elements.set_value", **{**leaf, "value": old})
    status = client.call("analysis.reference_status")
    assert not next(row["current"] for row in status["files"] if row["file"] == file), status
    return ids


def assert_index(client, ids):
    result = client.call("records.referenced_by", **ids["ReferenceKeyA"], limit=500)
    names = set()
    while True:
        names.update(hit["object"]["editorId"] for hit in result["hits"])
        if result["complete"]:
            break
        result = client.call("records.referenced_by", **ids["ReferenceKeyA"], cursor=result["nextCursor"], limit=500)
    assert names == {f"ReferenceCaller{i:04d}" for i in range(COUNT)}, len(names)
    # Empty type6/9 groups still participate in native owner linking.
    owner = client.call("elements.children", **ids["ReferenceEmptyOwner"], limit=50)
    assert any(row["object"]["kind"] == "child_group" for row in owner["children"]), owner


def exercise(client, overlay, artifacts):
    before = {name: (overlay / name).read_bytes() for name in fixtures()}
    timings, snapshots = [], []
    ids = {file: stale_file(client, file) for file in fixtures()}
    baseline = client.call("session.get_dirty_state")
    job = start(client, {"files": [CANCELED]})
    dry = poll(client, job, lambda s: s["terminal"], timings)
    assert dry["state"] == "succeeded" and dry["dryRun"], dry
    snapshots.append(dry)
    assert client.call("session.get_dirty_state") == baseline
    job = start(client, {"files": [CANCELED]}, False)
    partial = poll(client, job, lambda s: s["progress"]["detail"]["scanWorkUnits"] > 128 and
                   not s["progress"]["detail"]["stageComplete"], timings)
    status = client.call("analysis.reference_status")
    assert not next(row["current"] for row in status["files"] if row["file"] == CANCELED), status
    canceled = client.call("jobs.cancel", jobId=job)
    validate_state(canceled)
    assert canceled["state"] == "canceled" and canceled["result"] == partial["result"], canceled
    assert canceled["progress"] == partial["progress"] and not canceled["cursorRetained"], canceled
    assert client.call("jobs.get", jobId=job) == canceled
    snapshots.append(canceled)
    client.call("jobs.discard", jobId=job)
    refused = client.request(json.dumps({"command": "records.referenced_by", "args": ids[CANCELED]["ReferenceKeyA"]}))
    assert not refused["ok"] and refused["error"]["code"] == "state_conflict", refused
    assert client.call("session.get_dirty_state") == baseline
    # Resume all files and verify the canceled roots plus all reverse edges.
    job = start(client, {"allLoaded": True}, False)
    final = poll(client, job, lambda s: s["terminal"], timings)
    assert final["state"] == "succeeded" and final["summary"]["selectedScopeComplete"], final
    assert final["result"]["status"]["allLoadedCurrent"], final
    snapshots.append(final)
    for file in fixtures():
        assert_index(client, ids[file])
    # Current-file route must retain native fast path and complete with no scan actions.
    job = start(client, {"files": [STEPPED]}, False)
    noop = poll(client, job, lambda s: s["terminal"], timings)
    assert noop["state"] == "succeeded" and noop["result"]["steps"][0]["workUnits"] == 0, noop
    snapshots.append(noop)
    assert client.call("session.get_dirty_state") == baseline
    assert all((overlay / name).read_bytes() == blob for name, blob in before.items())
    (artifacts / "reference-step-report.json").write_text(json.dumps({"snapshots": snapshots,
        "pollSeconds": timings, "cachePolicy": "native fast path; stale indexes rebuilt without cache streams",
        "timingScope": "IPC plus native atoms; no latency guarantee"}, indent=2), encoding="utf-8")


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
        for name, blob in fixtures().items():
            with (args.overlay / name).open("xb") as output:
                output.write(blob)
    else:
        if not args.exe or not args.pid or not args.artifacts:
            parser.error("exercise requires --exe, --pid and --artifacts")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        exercise(Client(args.exe, args.pid, args.artifacts), args.overlay, args.artifacts)


if __name__ == "__main__":
    main()
