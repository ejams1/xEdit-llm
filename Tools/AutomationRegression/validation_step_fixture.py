"""Exercise retained validation cursors on large disposable FO4 plugins.

Generate into a fresh MO2 overlay; launch a newly compiled daemon through MO2.
Python fixture checks do not compile Delphi or verify native runtime behavior.
"""
import argparse
import json
from pathlib import Path
import time

from itm_fixture import Client, plugin, record, subrecord
from pagination_fixture import drain

MASTER = "AutomationValidationStepMaster.esm"
PLUGIN = "AutomationValidationStepOverride.esp"
KINDS = ("validation.check_for_itm", "validation.check_for_errors",
         "validation.check_for_deleted_refs")
COUNT = 3200
CAPACITY_COUNT = 6000


def fixture_bytes(capacity=False):
    count = CAPACITY_COUNT if capacity else COUNT
    master, override = [], []
    for index in range(count):
        payload = subrecord(b"EDID", f"AutomationStep{index:04d}".encode() + b"\0")
        form_id = 0x01000800 + index
        master.append(record(b"KYWD", payload, form_id=form_id))
        # Alternating header-only differences must never become ITM findings.
        flags = 0 if capacity or index % 2 == 0 else 0x400
        override.append(record(b"KYWD", payload, flags, form_id))
    next_id = 0x800 + count
    return {MASTER: plugin(["Fallout4.esm"], b"".join(master), True,
                           record_count=count, next_object_id=next_id),
            PLUGIN: plugin(["Fallout4.esm", MASTER], b"".join(override),
                           record_count=count, next_object_id=next_id)}


def validate_progress(state):
    progress = state["progress"]
    assert 0 <= progress["completed"] <= progress["total"], state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    detail = progress["detail"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["retainedDepth"] <= 64, state
    assert detail["softBudgetMs"] == 20 and not detail["nativeCallsPreemptible"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    if state["state"] in ("succeeded", "failed", "canceled"):
        assert not state["cursorRetained"], state
    if state["state"] == "succeeded":
        assert progress["remaining"] == 0 and detail["fileComplete"], state
        assert detail["retainedDepth"] == 0, state
        assert all(row["complete"] for row in state["result"]["files"]), state
    return detail


def advance(client, job_id, timings):
    started = time.monotonic()
    state = client.call("jobs.get", jobId=job_id)
    timings.append(time.monotonic() - started)
    validate_progress(state)
    return state


def finish(client, job_id, timings):
    for _ in range(10000):
        state = advance(client, job_id, timings)
        if state["terminal"]:
            return state
    raise AssertionError("Job did not finish within 10000 polls")


def findings(client, job_id):
    result, offset = [], 0
    while True:
        page = client.call("jobs.findings", jobId=job_id, offset=offset, limit=37)
        result.extend(page["findings"])
        offset += len(page["findings"])
        if offset == page["total"]:
            return result
        assert page["findings"], page


def identity(finding):
    target = finding["target"]
    return (target["file"], target.get("formId", "").replace(" ", ""), target["path"])


def exercise(client, artifacts, capacity=False):
    before = client.call("session.get_dirty_state")
    records, _ = drain(client, "records.list", "records",
                       {"file": PLUGIN, "signature": "KYWD", "limit": 37})
    count = CAPACITY_COUNT if capacity else COUNT
    assert len(records) == count, len(records)
    expected_itm = {(PLUGIN, entry["locator"]["formId"].replace(" ", ""), "")
                    for entry in records
                    if capacity or int(entry["object"]["editorId"][-4:]) % 2 == 0}
    timings, results = [], {}
    for kind in (KINDS[:1] if capacity else KINDS):
        queued = client.call("jobs.start", kind=kind, target={"files": [PLUGIN]})
        job_id = queued["jobId"]
        # Get beyond initialization and retain actual ITM findings before cancel.
        for _ in range(1000):
            partial = advance(client, job_id, timings)
            assert partial["state"] == "running", partial
            assert partial["progress"]["completed"] == 0, partial
            if (partial["progress"]["detail"]["visitedElements"] >= 200 and
                    (kind != KINDS[0] or partial["findingCount"] > 0)):
                break
        else:
            raise AssertionError("No within-file partial traversal was exposed")
        retained = findings(client, job_id)
        assert len(retained) == partial["findingCount"], partial
        denied = client.request(json.dumps({"command": "session.save", "args": {}}))
        assert denied["error"]["code"] == "job_busy", denied
        client.call("session.get_dirty_state")
        canceled = client.call("jobs.cancel", jobId=job_id)
        validate_progress(canceled)
        assert canceled["state"] == "canceled", canceled
        assert canceled["progress"] == partial["progress"], canceled
        assert not canceled["result"]["files"][0]["complete"], canceled
        assert findings(client, job_id) == retained
        assert client.call("jobs.get", jobId=job_id) == canceled
        client.call("jobs.discard", jobId=job_id)

        restarted = client.call("jobs.start", kind=kind, target={"files": [PLUGIN]})
        final = finish(client, restarted["jobId"], timings)
        complete_findings = findings(client, restarted["jobId"])
        assert complete_findings[:len(retained)] == retained
        if capacity:
            assert final["state"] == "failed" and final["failure"]["code"] == "job_capacity", final
            assert 0 < len(complete_findings) <= 5000, final
            assert final["progress"]["completed"] == 0, final
            assert not final["result"]["files"][0]["complete"], final
            actual = [identity(f) for f in complete_findings]
            assert len(actual) == len(set(actual)) and set(actual) <= expected_itm
        else:
            assert final["state"] == "succeeded", final
            assert final["summary"]["fileCount"] == 1, final
            assert final["summary"]["findingCount"] == len(complete_findings), final
            if kind == KINDS[0]:
                actual = [identity(f) for f in complete_findings if f["code"] == "itm_record"]
                assert len(actual) == len(set(actual)) and set(actual) == expected_itm, final
            elif kind == KINDS[2]:
                assert [f["code"] for f in complete_findings] == ["no_deleted_refs_found"], complete_findings
        assert final["findingCount"] == len(complete_findings), final
        results[kind] = final
        client.call("jobs.discard", jobId=restarted["jobId"])
    after = client.call("session.get_dirty_state")
    assert before == after, (before, after)
    report = {"capacity": capacity, "records": count, "pollSeconds": timings,
              "maxPollSeconds": max(timings), "jobs": results,
              "dirtyBefore": before, "dirtyAfter": after,
              "timingIncludesClientProcessAndIPC": True,
              "hardLatencyGuaranteeTested": False}
    (artifacts / "validation-steps.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("generate", "exercise"))
    parser.add_argument("--capacity", action="store_true")
    parser.add_argument("--overlay", type=Path)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        if args.overlay is None:
            parser.error("Generate requires --overlay (a fresh MO2 mod directory)")
        args.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixture_bytes(args.capacity).items():
            with (args.overlay / name).open("xb") as stream:
                stream.write(data)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Exercise requires --exe, --pid and --artifacts")
        report = exercise(Client(args.exe, args.pid, args.artifacts), args.artifacts, args.capacity)
        print(f"Validation cursor checks passed; longest client poll {report['maxPollSeconds']:.3f}s")


if __name__ == "__main__":
    main()
