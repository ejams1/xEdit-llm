"""FO4 retained compaction planning, atomic remaps and cross-file persistence.

Load Fallout4.esm, BASE, TARGET, CALLERS, CANCELED, CANCEL_CALLERS in order in a
fresh disposable overlay. Exercise needs edit consent; verify uses a fresh PID.
Python tests validate fixture/assertion integrity, not native xEdit behavior.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client
from row_fixture import disk_state, keyword, form_list
from selective_step_fixture import group, records, object_id
from esl_step_fixture import plugin
from hygiene_step_fixture import raw_headers
from validation_step_fixture import findings

BASE = "AutomationCompactBase.esm"
TARGET = "AutomationCompactStepped.esp"
CALLERS = "AutomationCompactCallers.esp"
CANCELED = "AutomationCompactCanceled.esp"
CANCEL_CALLERS = "AutomationCompactCancelCallers.esp"
COUNT = 400
KIND = "plugin.formids.compact_for_esl"


def expected_remaps():
    free = iter(value for value in range(0x800, 0x1000) if value not in (0x800, 0x802, 0xA00))
    return {0x10000 + i: next(free) for i in range(COUNT)}


def fixtures():
    result = {BASE: plugin(["Fallout4.esm"], [group(b"KYWD", 0,
                       keyword("CompactInherited", 0x01000800))], 1, 0x801, True)}
    for target, callers in ((TARGET, CALLERS), (CANCELED, CANCEL_CALLERS)):
        # Descending on disk: ascending mapping must be independent of native tree order.
        rows = b"".join(keyword(f"CompactHigh{i:04d}", 0x02010000 + i) for i in reversed(range(COUNT)))
        rows += keyword("CompactPin800", 0x02000800) + keyword("CompactPin802", 0x02000802)
        rows += keyword("CompactInherited", 0x01000800)
        own = form_list("CompactInternal", 0x02000A00, [0x02010000, 0x02010000 + COUNT - 1])
        result[target] = plugin(["Fallout4.esm", BASE], [group(b"KYWD", 0, rows),
                                group(b"FLST", 0, own)], COUNT + 4, 0x10000 + COUNT)
        # Override AND editable external referrer; both must follow target remaps.
        result[callers] = plugin(["Fallout4.esm", BASE, target], [group(b"KYWD", 0,
            keyword("CompactHigh0000", 0x02010000)), group(b"FLST", 0,
            form_list("CompactExternal", 0x03003000, [0x02010000, 0x02010000 + COUNT - 1]))], 2, 0x3001)
    return result


def validate_state(state):
    detail, progress = state["progress"]["detail"], state["progress"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["totalWorkUnits"] <= detail["totalWorkLimit"] == 1000000, state
    assert 0 <= detail["retainedDepth"] <= detail["depthLimit"] == 64, state
    assert 0 <= detail["newRecordCount"] <= detail["recordCapacity"] <= 4095, state
    assert 0 <= detail["appliedRemaps"] <= detail["remapCount"] <= detail["newRecordCount"], state
    assert 0 <= detail["loadedFilesProcessed"] <= detail["loadedFilesTotal"], state
    assert 0 <= detail["referrersChecked"] <= detail["relationshipsPerRemapLimit"] == 100000, state
    assert 0 <= detail["overridesChecked"] <= 100000, state
    assert detail["mutationLimit"] == 1 and detail["softBudgetMs"] == 20, state
    assert not detail["nativeCallsPreemptible"], state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    rows = state["result"]["files"]
    assert sum(row["complete"] for row in rows) == progress["completed"], state
    assert state["summary"].get("applied", 0) == sum(row["appliedRemaps"] for row in rows), state
    for row in rows:
        outcomes = [item["outcome"] for item in row["remaps"]]
        assert row["remapCount"] == len(outcomes), row
        assert row["appliedRemaps"] == outcomes.count("applied"), row
        if row["appliedRemaps"]:
            assert row["planningComplete"] and row["preflightComplete"], row
            assert row["changed"] and row["requiresSave"], row
        if state["dryRun"]:
            assert not row["appliedRemaps"] and not row["changed"], row
        if row["complete"]:
            assert row["planningComplete"] and all(o in ("planned", "applied") for o in outcomes), row
    if state["terminal"]:
        assert not state["cursorRetained"], state


def start(client, files, dry=None):
    args = {"kind": KIND, "target": {"files": files}}
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
    raise AssertionError("Compaction did not reach requested boundary")


def cancel(client, job, partial):
    events = findings(client, job)
    state = client.call("jobs.cancel", jobId=job)
    validate_state(state)
    assert state["state"] == "canceled" and state["result"] == partial["result"], state
    assert state["progress"] == partial["progress"] and findings(client, job) == events
    assert client.call("jobs.get", jobId=job) == state
    client.call("jobs.discard", jobId=job)
    return state


def mapping(row):
    return {object_id({"formId": item["oldFormId"]}): object_id({"formId": item["newFormId"]})
            for item in row["remaps"]}


def assert_loaded(client, target, callers, applied):
    expected = expected_remaps()
    for file in (target, callers):
        keywords = {entry["object"]["editorId"]: object_id(entry["locator"])
                    for entry in records(client, file, "KYWD")}
        indices = range(COUNT) if file == target else (0,)
        for i in indices:
            old = 0x10000 + i
            assert keywords[f"CompactHigh{i:04d}"] == (expected[old] if old in applied else old), keywords
        lists = records(client, file, "FLST")
        assert len(lists) == 1, lists
        links = client.call("records.references", **lists[0]["locator"])
        assert links["complete"] and len(links["hits"]) == 2, links
        observed = {hit["object"]["editorId"]: object_id(hit["locator"]) for hit in links["hits"]}
        for i in (0, COUNT - 1):
            old = 0x10000 + i
            assert observed[f"CompactHigh{i:04d}"] == (expected[old] if old in applied else old), links
    assert not client.call("files.get_header", file=target)["isLight"]


def exercise(client, overlay, artifacts):
    before = {name: (overlay / name).read_bytes() for name in fixtures()}
    baseline = client.call("session.get_dirty_state")
    assert not baseline["dirty"], baseline
    timings, snapshots = [], []
    for files in ([TARGET, "Missing.esp"], [TARGET, TARGET], [], [TARGET] * 257):
        reply = client.request(json.dumps({"command": "jobs.start", "args": {
            "kind": KIND, "dryRun": False, "target": {"files": files}}}))
        assert not reply["ok"], reply
    for phase in ("file-tree", "sort", "preflight", "apply-remaps"):
        job = start(client, [CANCELED], False)
        state = poll(client, job, lambda s: s["progress"]["detail"]["phase"] == phase and
                     (phase != "file-tree" or s["progress"]["detail"]["totalWorkUnits"] > 128), timings)
        assert not state["summary"].get("changed", False), state
        snapshots.append(cancel(client, job, state))
        assert client.call("session.get_dirty_state") == baseline
        assert_loaded(client, CANCELED, CANCEL_CALLERS, set())
    job = start(client, [TARGET])  # omitted dryRun is true.
    dry = poll(client, job, lambda s: s["terminal"], timings)
    assert dry["state"] == "succeeded" and dry["dryRun"], dry
    assert dry["summary"]["planned"] == COUNT and mapping(dry["result"]["files"][0]) == expected_remaps(), dry
    snapshots.append(dry)
    assert client.call("session.get_dirty_state") == baseline
    # One complete native remap, including override/referrers, before cancellation.
    job = start(client, [CANCELED], False)
    partial = poll(client, job, lambda s: s["progress"]["detail"]["appliedRemaps"] == 1, timings)
    assert_loaded(client, CANCELED, CANCEL_CALLERS, {0x10000})
    assert partial["summary"]["changed"] and partial["summary"]["requiresSave"], partial
    denied = client.request(json.dumps({"command": "session.save", "args": {"files": [CANCELED]}}))
    assert denied["error"]["code"] == "job_busy", denied
    snapshots.append(cancel(client, job, partial))
    # Retry preserves occupied 0x801 from the first remap and reaches identical final IDs.
    for target, callers in ((CANCELED, CANCEL_CALLERS), (TARGET, CALLERS)):
        job = start(client, [target], False)
        final = poll(client, job, lambda s: s["terminal"], timings)
        assert final["state"] == "succeeded", final
        assert final["summary"]["applied"] == COUNT - int(target == CANCELED), final
        assert {target, callers} <= set(final["summary"]["dirtyFiles"]), final
        snapshots.append(final)
        assert_loaded(client, target, callers, set(expected_remaps()))
    job = start(client, [TARGET], False)
    noop = poll(client, job, lambda s: s["terminal"], timings)
    assert noop["state"] == "succeeded" and not noop["summary"].get("changed", False), noop
    assert not noop["result"]["files"][0]["remapCount"], noop
    snapshots.append(noop)
    assert all((overlay / name).read_bytes() == blob for name, blob in before.items())
    (artifacts / "compact-step-report.json").write_text(json.dumps({"snapshots": snapshots,
        "pollSeconds": timings, "timingScope": "IPC and indivisible native calls; no latency guarantee"}, indent=2), encoding="utf-8")
    client.call("session.save", files=[TARGET, CALLERS, CANCELED, CANCEL_CALLERS])
    client.call("session.flush")


def verify(client, overlay):
    assert (overlay / BASE).read_bytes() == fixtures()[BASE]
    expected = expected_remaps()
    for target, callers in ((TARGET, CALLERS), (CANCELED, CANCEL_CALLERS)):
        assert_loaded(client, target, callers, set(expected))
        target_blob = (overlay / target).read_bytes()
        assert struct.unpack_from("<I", target_blob, 38)[0] == 0xA01  # native NextObjectID
        for file in (target, callers):
            names, rows = disk_state((overlay / file).read_bytes())
            assert names == ["Fallout4.esm", BASE] + ([target] if file == callers else []), names
            indices = range(COUNT) if file == target else (0,)
            for i in indices:
                assert rows[f"CompactHigh{i:04d}"]["identity"] == expected[0x10000 + i]
            own = rows["CompactInternal" if file == target else "CompactExternal"]
            assert [struct.unpack("<I", value)[0] for value in own["fields"][b"LNAM"]] == [
                0x02000000 | expected[0x10000], 0x02000000 | expected[0x10000 + COUNT - 1]], own
        assert disk_state(target_blob) == disk_state((overlay / CANCELED).read_bytes())


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
            parser.error("exercise/verify require --exe, --pid, --artifacts")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        client = Client(args.exe, args.pid, args.artifacts)
        if args.phase == "exercise":
            exercise(client, args.overlay, args.artifacts)
        else:
            verify(client, args.overlay)


if __name__ == "__main__":
    main()
