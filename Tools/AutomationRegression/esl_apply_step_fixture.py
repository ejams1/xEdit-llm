"""FO4 ESL apply composition: read-only analysis, compaction, then separate flag.

Use a fresh compact-step overlay plus ELIGIBLE and TOO_MANY loaded last. Do not
run the standalone compact runner first. Exercise edits/saves; verify uses a fresh
PID. Native execution is deliberately separate from Python assertion tests.
"""
import argparse
import json
from pathlib import Path
import struct
import time

import compact_step_fixture as compact
from itm_fixture import Client
from row_fixture import disk_state, keyword
from selective_step_fixture import group, records
from esl_step_fixture import plugin
from validation_step_fixture import findings

ELIGIBLE = "AutomationEslApplyEligible.esp"
TOO_MANY = "AutomationEslApplyTooMany.esp"
KIND = "plugin.esl.apply"


def object_id(locator):
    value = int(locator["formId"].replace(" ", ""), 16)
    return value & (0xFFF if value >> 24 == 0xFE else 0xFFFFFF)


def fixtures():
    result = compact.fixtures()
    result[ELIGIBLE] = plugin(["Fallout4.esm"], [group(b"KYWD", 0,
        keyword("EslApplyAlreadyInRange", 0x01000800))], 1, 0x801)
    result[TOO_MANY] = plugin(["Fallout4.esm"], [group(b"KYWD", 0,
        b"".join(keyword(f"EslApplyExcess{i:04d}", 0x01010000 + i) for i in range(4100)))], 4100, 0x11004)
    return result


def validate_state(state):
    detail, progress = state["progress"]["detail"], state["progress"]
    assert detail["workLimit"] == 128 and detail["softBudgetMs"] == 20, state
    assert detail["mutationLimit"] == 1 and not detail["nativeCallsPreemptible"], state
    assert type(state["summary"]["planned"]) is int and type(state["summary"]["applied"]) is int, state
    cursor = detail.get("cursor", {})
    if cursor:
        assert 0 <= cursor["lastWorkUnits"] <= cursor["workLimit"] == 128, state
        assert 0 <= cursor["retainedDepth"] <= cursor["depthLimit"] == 64, state
        assert 0 <= cursor["totalWorkUnits"] <= cursor["totalWorkLimit"] == 1000000, state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    rows = state["result"]["files"]
    assert sum(row["complete"] for row in rows) == progress["completed"], state
    assert state["summary"].get("remapsApplied", 0) == sum(row["appliedRemaps"] for row in rows), state
    assert state["summary"].get("remapsPlanned", 0) == sum(row.get("plannedRemaps", 0) for row in rows), state
    assert state["summary"].get("applied", 0) == sum(
        row.get("eslFlagChanged", False) and row["flagOutcome"] == "applied" for row in rows), state
    for row in rows:
        if row["appliedRemaps"]:
            assert row["analysisComplete"] and row["planningComplete"] and row["preflightComplete"], row
        if row["flagOutcome"] in ("applying", "applied", "planned"):
            assert row["analysisComplete"], row
            if row["requiresCompact"]:
                assert row["planningComplete"] and row["preflightComplete"], row
                assert row["appliedRemaps"] == row["remapCount"] if not state["dryRun"] else not row["appliedRemaps"]
        if row["complete"]:
            assert row["flagOutcome"] in ("planned", "applied"), row
        if state["dryRun"]:
            assert not row["appliedRemaps"] and not row["mutationState"]["mutationsObserved"], row
    if state["dryRun"]:
        assert not state["summary"].get("changed", False), state
    if state["terminal"]:
        assert not state["cursorRetained"], state


def start(client, files, dry=None, allow=True):
    args = {"kind": KIND, "target": {"files": files}, "options": {"allowAfterCompact": allow}}
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
    raise AssertionError("ESL apply did not reach requested boundary")


def cancel(client, job, partial):
    events = findings(client, job)
    state = client.call("jobs.cancel", jobId=job)
    validate_state(state)
    assert state["state"] == "canceled" and state["result"] == partial["result"], state
    assert state["progress"] == partial["progress"] and findings(client, job) == events
    assert client.call("jobs.get", jobId=job) == state
    client.call("jobs.discard", jobId=job)
    return state


def assert_loaded(client, target, callers, applied, light):
    expected = compact.expected_remaps()
    for file in (target, callers):
        keywords = {entry["object"]["editorId"]: object_id(entry["locator"])
                    for entry in records(client, file, "KYWD")}
        for i in (range(compact.COUNT) if file == target else (0,)):
            old = 0x10000 + i
            assert keywords[f"CompactHigh{i:04d}"] == (expected[old] if old in applied else old), keywords
        lists = records(client, file, "FLST")
        assert len(lists) == 1, lists
        links = client.call("records.references", **lists[0]["locator"])
        assert links["complete"] and len(links["hits"]) == 2, links
        observed = {hit["object"]["editorId"]: object_id(hit["locator"]) for hit in links["hits"]}
        for i in (0, compact.COUNT - 1):
            old = 0x10000 + i
            assert observed[f"CompactHigh{i:04d}"] == (expected[old] if old in applied else old), links
    assert client.call("files.get_header", file=target)["isLight"] == light


def exercise(client, overlay, artifacts):
    before = {name: (overlay / name).read_bytes() for name in fixtures()}
    baseline = client.call("session.get_dirty_state")
    assert not baseline["dirty"], baseline
    timings, snapshots = [], []
    # Eligibility rejection and over-capacity blockers finish analysis without edits.
    for file, allow in ((compact.TARGET, False), (TOO_MANY, True)):
        job = start(client, [file], False, allow)
        refused = poll(client, job, lambda s: s["terminal"], timings)
        assert refused["state"] == "failed" and refused["failure"]["code"] == "eligibility_failed", refused
        assert refused["result"]["files"][0]["analysisComplete"], refused
        snapshots.append(refused)
        client.call("jobs.discard", jobId=job)
        assert client.call("session.get_dirty_state") == baseline
    job = start(client, [compact.TARGET])
    dry = poll(client, job, lambda s: s["terminal"], timings)
    assert dry["state"] == "succeeded" and dry["dryRun"], dry
    assert dry["summary"]["applied"] == 0, dry
    assert dry["summary"]["planned"] == 1 and dry["summary"]["remapsPlanned"] == compact.COUNT, dry
    assert dry["result"]["files"][0]["changed"] and not dry["summary"]["changed"], dry
    assert compact.mapping(dry["result"]["files"][0]) == compact.expected_remaps(), dry
    snapshots.append(dry)
    assert client.call("session.get_dirty_state") == baseline
    for boundary in (lambda s: s["progress"]["detail"]["phase"] == "analyze" and
                     s["progress"]["detail"]["cursor"]["totalWorkUnits"] > 128,
                     lambda s: s["progress"]["detail"]["phase"] == "compact" and
                     s["progress"]["detail"]["cursor"].get("phase") == "apply-remaps"):
        job = start(client, [compact.CANCELED], False)
        partial = poll(client, job, boundary, timings)
        snapshots.append(cancel(client, job, partial))
        assert_loaded(client, compact.CANCELED, compact.CANCEL_CALLERS, set(), False)
        assert client.call("session.get_dirty_state") == baseline
    job = start(client, [compact.CANCELED], False)
    partial = poll(client, job, lambda s: s["progress"]["detail"]["appliedRemaps"] == 1, timings)
    assert_loaded(client, compact.CANCELED, compact.CANCEL_CALLERS, {0x10000}, False)
    snapshots.append(cancel(client, job, partial))
    # Complete remaining compaction, pause BEFORE flag, then cancel without setting ESL.
    job = start(client, [compact.CANCELED], False)
    compacted = poll(client, job, lambda s: s["progress"]["detail"]["phase"] == "esl-flag", timings)
    assert not compacted["terminal"] and compacted["result"]["files"][0]["compacted"], compacted
    assert_loaded(client, compact.CANCELED, compact.CANCEL_CALLERS, set(compact.expected_remaps()), False)
    snapshots.append(cancel(client, job, compacted))
    for files in ([compact.CANCELED], [compact.TARGET, ELIGIBLE]):
        job = start(client, files, False)
        final = poll(client, job, lambda s: s["terminal"], timings)
        assert final["state"] == "succeeded" and final["summary"]["applied"] == len(files), final
        assert final["summary"]["planned"] == 0, final
        snapshots.append(final)
    for target, callers in ((compact.TARGET, compact.CALLERS), (compact.CANCELED, compact.CANCEL_CALLERS)):
        assert_loaded(client, target, callers, set(compact.expected_remaps()), True)
    assert client.call("files.get_header", file=ELIGIBLE)["isLight"]
    job = start(client, [ELIGIBLE], False, False)
    noop = poll(client, job, lambda s: s["terminal"], timings)
    assert noop["state"] == "succeeded" and not noop["summary"].get("applied", 0), noop
    assert not noop["summary"].get("changed", False), noop
    snapshots.append(noop)
    assert all((overlay / name).read_bytes() == blob for name, blob in before.items())
    (artifacts / "esl-apply-step-report.json").write_text(json.dumps({"snapshots": snapshots,
        "pollSeconds": timings, "timingScope": "IPC plus native atoms, no latency guarantee"}, indent=2), encoding="utf-8")
    client.call("session.save", files=[compact.TARGET, compact.CALLERS, compact.CANCELED,
                                      compact.CANCEL_CALLERS, ELIGIBLE])
    client.call("session.flush")


def verify(client, overlay):
    expected = compact.expected_remaps()
    for name in (compact.BASE, TOO_MANY):
        assert (overlay / name).read_bytes() == fixtures()[name], name
    for target, callers in ((compact.TARGET, compact.CALLERS), (compact.CANCELED, compact.CANCEL_CALLERS)):
        assert_loaded(client, target, callers, set(expected), True)
        blob = (overlay / target).read_bytes()
        assert struct.unpack_from("<I", blob, 8)[0] & 0x200
        assert struct.unpack_from("<I", blob, 38)[0] == 0xA01
        for file in (target, callers):
            names, rows = disk_state((overlay / file).read_bytes())
            assert names == ["Fallout4.esm", compact.BASE] + ([target] if file == callers else []), names
            for i in (range(compact.COUNT) if file == target else (0,)):
                assert rows[f"CompactHigh{i:04d}"]["identity"] == expected[0x10000 + i]
            own = rows["CompactInternal" if file == target else "CompactExternal"]
            assert [struct.unpack("<I", value)[0] for value in own["fields"][b"LNAM"]] == [
                0x02000000 | expected[0x10000], 0x02000000 | expected[0x10000 + compact.COUNT - 1]], own
    assert client.call("files.get_header", file=ELIGIBLE)["isLight"]
    assert struct.unpack_from("<I", (overlay / ELIGIBLE).read_bytes(), 8)[0] & 0x200


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
