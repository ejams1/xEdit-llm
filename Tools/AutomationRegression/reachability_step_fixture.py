"""FO4 retained reachability report/root cancellation; native acceptance only.

Generate a fresh dedicated MO2 overlay; load Fallout4.esm, BASE, PATCH in order.
References/reset/report retain cursors; native root-file discovery and each root
propagation remain indivisible. This runner checks within-file cancellation,
derived-state invalidity, repeat classifications and unchanged disk bytes.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord
from reachability_fixture import BASE, PATCH, group
from selective_step_fixture import records
from validation_step_fixture import findings
from row_fixture import children, at

FILLERS = 700


def plugin(masters, body, count, esm=False):
    header = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0x2000))
    for name in masters:
        header += subrecord(b"MAST", name.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    return record(b"TES4", header, int(esm)) + body


def fixtures():
    lists = b""
    for index, (name, link) in enumerate((("ReachA", 0x01000801), ("ReachB", 0x01000800),
                                        ("IsolatedC", 0x01000803), ("IsolatedD", 0x01000802)), 0x800):
        body = subrecord(b"EDID", name.encode() + b"\0") + subrecord(b"LNAM", struct.pack("<I", link))
        lists += record(b"FLST", body, form_id=0x01000000 + index)
    for index in range(FILLERS):
        body = subrecord(b"EDID", f"ReachStepUnused{index:04d}".encode() + b"\0")
        lists += record(b"FLST", body, form_id=0x01001000 + index)
    root = subrecord(b"EDID", b"ReachRoot\0") + subrecord(b"DATA", struct.pack("<I", 0x01000800))
    return {BASE: plugin(["Fallout4.esm"], group(b"FLST", lists), FILLERS + 4, True),
            PATCH: plugin(["Fallout4.esm", BASE], group(b"DFOB", record(b"DFOB", root, form_id=0x02000800)), 1)}


def validate_state(state):
    progress, detail = state["progress"], state["progress"]["detail"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["processed"] <= detail["total"], state
    assert 1 <= detail["remainingNativeVisitBudget"] <= 5000000, state
    assert not detail["nativeCallsPreemptible"] and detail["softBudgetMs"] == 20, state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    if state["terminal"]:
        assert not state["cursorRetained"], state
    if state["state"] == "succeeded":
        assert progress["remaining"] == 0 and detail["stageComplete"], state
    if "referenceCursor" in detail:
        cursor = detail["referenceCursor"]
        assert 0 <= cursor["scanWorkUnits"] <= cursor["scanWorkLimit"] == 1000000, state
        assert 0 <= cursor["nativeUnits"] <= cursor["scanWorkUnits"], state
        assert 0 <= cursor["retainedDepth"] <= cursor["depthLimit"] == 128, state
        assert cursor["stageComplete"] == detail["stageComplete"], state
    if "resetWorkUnits" in detail:
        assert 0 <= detail["resetWorkUnits"] <= detail["resetWorkLimit"] == 15000000, state
        assert 0 <= detail["retainedDepth"] <= detail["depthLimit"] == 128, state


def start(client, roots=None, dry=False):
    target = {"files": [BASE, PATCH]}
    if roots is not None:
        target["roots"] = roots
    return client.call("jobs.start", kind="analysis.reachability", target=target, dryRun=dry)["jobId"]


def poll(client, job, predicate, timings):
    for _ in range(20000):
        began = time.monotonic()
        state = client.call("jobs.get", jobId=job)
        timings.append(time.monotonic() - began)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("Reachability did not reach requested boundary")


def cancel(client, job, partial):
    events = findings(client, job)
    canceled = client.call("jobs.cancel", jobId=job)
    validate_state(canceled)
    assert canceled["state"] == "canceled" and canceled["progress"] == partial["progress"], canceled
    assert canceled["result"] == partial["result"] and findings(client, job) == events
    assert not canceled["summary"].get("analysisComplete", False), canceled
    assert client.call("jobs.get", jobId=job) == canceled
    client.call("jobs.discard", jobId=job)
    return canceled


def assert_classifications(rows, explicit=False):
    by_name = {row["editorId"]: row for row in rows}
    assert len(rows) == len(by_name) == FILLERS + 5, rows
    assert by_name["ReachA"]["reachable"] and by_name["ReachB"]["reachable"], rows
    for name in ("IsolatedC", "IsolatedD", "ReachStepUnused0000", "ReachStepUnused0001"):
        assert by_name[name]["reachable"] == explicit, by_name[name]
        assert by_name[name]["notReachable"] != explicit, by_name[name]
    for index in range(2, FILLERS):
        assert by_name[f"ReachStepUnused{index:04d}"]["notReachable"], index
    assert all(row["validity"] == "historical classification only if containing job succeeds" for row in rows)


def exercise(client, overlay, artifacts):
    before = {name: (overlay / name).read_bytes() for name in fixtures()}
    ids = {row["object"]["editorId"]: row["locator"] for row in records(client, BASE, "FLST")}
    # Stale the index while restoring exact live payload; this intentionally
    # leaves a dirty baseline, with no save. Later analysis must preserve it.
    link = children(client, at(ids["ReachA"], "FormIDs"))[0]
    old = client.call("elements.get_value", **link)["values"]["editValue"]
    client.call("elements.set_value", **{**link, "value": ids["IsolatedC"]["formId"]})
    client.call("elements.set_value", **{**link, "value": old})
    baseline = client.call("session.get_dirty_state")
    roots = [ids[name] for name in ("IsolatedC", "ReachStepUnused0000", "ReachStepUnused0001")]
    timings, snapshots = [], []
    planned_job = start(client, dry=True)
    planned = poll(client, planned_job, lambda s: s["terminal"], timings)
    assert planned["state"] == "succeeded" and not findings(client, planned_job), planned
    assert not planned["summary"].get("analysisComplete", False), planned
    snapshots.append(planned)
    reference_job = start(client)
    partial = poll(client, reference_job, lambda s: s["progress"]["detail"]["phase"] == "references" and
                   s["progress"]["detail"]["fileName"] == BASE and
                   s["progress"]["detail"]["referenceCursor"]["scanWorkUnits"] > 128 and
                   not s["progress"]["detail"]["stageComplete"], timings)
    snapshots.append(cancel(client, reference_job, partial))
    status = client.call("analysis.reference_status")
    assert not next(row["current"] for row in status["files"] if row["file"] == BASE), status
    reset_job = start(client)
    partial = poll(client, reset_job, lambda s: s["progress"]["detail"]["phase"] == "reset" and
                   s["progress"]["detail"]["fileName"] == BASE and
                   s["progress"]["detail"]["resetWorkUnits"] > 128 and
                   not s["progress"]["detail"]["stageComplete"], timings)
    assert partial["progress"]["detail"]["remainingNativeVisitBudget"] < 5000000, partial
    snapshots.append(cancel(client, reset_job, partial))
    refused = client.request(json.dumps({"command": "records.apply_filter", "args": {
        "files": [BASE], "notReachable": True}}))
    assert not refused["ok"] and refused["error"]["code"] == "state_conflict", refused
    root_job = start(client, roots)
    partial = poll(client, root_job, lambda s: s["progress"]["detail"]["phase"] == "additional-roots" and
                   s["progress"]["detail"]["processed"] == 1, timings)
    assert partial["progress"]["detail"]["lastWorkUnits"] == 1, partial
    assert partial["progress"]["detail"]["remainingNativeVisitBudget"] < 5000000, partial
    snapshots.append(cancel(client, root_job, partial))
    report_job = start(client)
    partial = poll(client, report_job, lambda s: s["progress"]["detail"]["phase"] == "report" and
                   0 < s["progress"]["detail"]["processed"] < s["progress"]["detail"]["total"], timings)
    assert partial["findingCount"] > 0 and not partial["result"]["steps"][-1]["complete"], partial
    snapshots.append(cancel(client, report_job, partial))
    for explicit in (False, True, False):
        job = start(client, roots if explicit else None)
        final = poll(client, job, lambda s: s["terminal"], timings)
        assert final["state"] == "succeeded" and final["summary"]["analysisComplete"], final
        rows = findings(client, job)
        assert_classifications(rows, explicit)
        assert final["summary"]["reportedRecords"] == len(rows), final
        snapshots.append(final)
    assert client.call("session.get_dirty_state") == baseline
    assert all((overlay / name).read_bytes() == blob for name, blob in before.items())
    (artifacts / "reachability-steps.json").write_text(json.dumps({"jobs": snapshots,
        "pollSeconds": timings, "hardLatencyGuaranteeTested": False}, indent=2), encoding="utf-8")


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
