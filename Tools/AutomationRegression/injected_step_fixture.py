"""FO4 global injected-cleanup preflight and copy-before-remove cancellation.

Load Fallout4.esm, BASE, SECOND, PROVIDER, OTHER in order in a fresh overlay.
Exercise uses edit consent and explicit save/terminal flush; verify uses a fresh
PID. Python tests verify binary/assertion integrity only.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord
from circular_fixture import leveled_record
from formid_fixture import plugin
from row_fixture import disk_state
from selective_step_fixture import records, object_id
from validation_step_fixture import findings

BASE = "AutomationInjectedStepBase.esm"
SECOND = "AutomationInjectedStepSecond.esm"
PROVIDER = "AutomationInjectedStepProvider.esp"
OTHER = "AutomationInjectedStepOther.esp"
COUNT = 100
FIRST_COUNT = 60
KIND = "cleaning.cleanup_injected_references"


def referrer(name, identity, injected=0x01002000):
    body = subrecord(b"EDID", name.encode() + b"\0") + subrecord(b"OBND", b"\0" * 12)
    body += subrecord(b"LVLD", b"\0") + subrecord(b"LVLF", b"\0") + subrecord(b"LLCT", b"\2")
    for level, target in ((1, injected), (2, 0x01000801)):
        body += subrecord(b"LVLO", struct.pack("<HHIHBB", level, 0, target, 1, 0, 0))
    return record(b"LVLI", body, form_id=identity)


def fixtures():
    first = leveled_record(b"LVLI", "InjectedStepControl", 0x01000801)
    first += referrer("InjectedStepOtherProvider", 0x01000980, 0x01003000)
    first += b"".join(referrer(f"InjectedStepRoot{i:03d}", 0x01001000 + i) for i in range(FIRST_COUNT))
    second = b"".join(referrer(f"InjectedStepRoot{i:03d}", 0x02001000 + i) for i in range(FIRST_COUNT, COUNT))
    return {BASE: plugin(["Fallout4.esm"], first, FIRST_COUNT + 2, True),
            SECOND: plugin(["Fallout4.esm", BASE], second, COUNT - FIRST_COUNT, True),
            PROVIDER: plugin(["Fallout4.esm", BASE, SECOND],
                leveled_record(b"LVLI", "InjectedStepPayload", 0x01002000), 1),
            OTHER: plugin(["Fallout4.esm", BASE],
                leveled_record(b"LVLI", "InjectedStepOtherPayload", 0x01003000), 1)}


def roots(client, file):
    return {entry["object"]["editorId"]: entry["locator"] for entry in records(client, file, "LVLI")}


def validate_state(state):
    detail, progress = state["progress"]["detail"], state["progress"]
    assert detail["nativeUnitLimit"] == 1 and not detail["nativeCallsPreemptible"], state
    assert 0 <= detail["loadedFilesProcessed"] <= detail["loadedFilesTotal"] <= detail["loadedFileLimit"] == 256, state
    assert 0 <= detail["globalRecordsPlanned"] <= detail["planCount"] <= detail["recordLimit"] == 128, state
    assert detail["planByteLimit"] == 524288, state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    data = state["result"]
    assert sum(row["complete"] for row in data["files"]) == progress["completed"], state
    plan, rows = data.get("plan", []), data.get("records", [])
    assert len(plan) == state["summary"].get("planned", 0), state
    assert len(plan) <= detail["planCount"], state
    assert state["summary"].get("applied", 0) == sum(row["complete"] for row in rows), state
    assert state["summary"].get("requiresManualReview", 0) == sum(
        row.get("requiresManualReview", False) and row["complete"] for row in rows), state
    for row in rows:
        assert data["preflight"]["complete"] and detail["globalPreflightComplete"], state
        if row["complete"] or row["cleaned"]:
            assert row["preservationComplete"] and row.get("preserved"), row
        if row["outcome"] == "preserved":
            assert row["preservationComplete"] and not row["cleaned"] and not row["complete"], row
    if state["dryRun"]:
        assert not rows and not state["summary"].get("changed", False), state
    if state["terminal"]:
        assert not state["cursorRetained"], state


def start(client, selected, dry=None, overwrite=False):
    args = {"kind": KIND, "target": {"files": [BASE, SECOND]},
            "options": {"records": selected, "overwrite": overwrite}}
    if dry is not None:
        args["dryRun"] = dry
    return client.call("jobs.start", **args)["jobId"]


def poll(client, job, predicate, timings):
    for _ in range(10000):
        began = time.monotonic()
        state = client.call("jobs.get", jobId=job)
        timings.append(time.monotonic() - began)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("Injected cleanup did not reach requested boundary")


def cancel(client, job, partial):
    events = findings(client, job)
    state = client.call("jobs.cancel", jobId=job)
    validate_state(state)
    assert state["state"] == "canceled" and state["result"] == partial["result"], state
    assert state["progress"] == partial["progress"] and findings(client, job) == events
    assert client.call("jobs.get", jobId=job) == state
    client.call("jobs.discard", jobId=job)
    return state


def link_ids(client, locator):
    result = client.call("records.references", **locator)
    assert result["complete"] and len(result["hits"]) <= 2, result
    return {object_id(hit["locator"]) for hit in result["hits"]}


def assert_loaded(client, completed, preserved):
    provider = roots(client, PROVIDER)
    sources = {**roots(client, BASE), **roots(client, SECOND)}
    for i in range(COUNT):
        name = f"InjectedStepRoot{i:03d}"
        source = sources[name]
        assert link_ids(client, source) == ({0x801} if i in completed else {0x801, 0x2000}), (i, source)
        assert (name in provider) == (i in preserved), (i, provider)
        if i in preserved:
            assert provider[name]["formId"] == source["formId"], (provider[name], source)
            assert link_ids(client, provider[name]) == {0x801, 0x2000}


def exercise(client, overlay, artifacts):
    before = {name: (overlay / name).read_bytes() for name in fixtures()}
    baseline = client.call("session.get_dirty_state")
    assert not baseline["dirty"], baseline
    native = {**roots(client, BASE), **roots(client, SECOND)}
    selected = [native[f"InjectedStepRoot{i:03d}"] for i in range(COUNT)]
    timings, snapshots = [], []
    # Deferred global provider preflight must reject a bad LATER selected record
    # without copying/cleaning the first otherwise-valid selection.
    job = start(client, [selected[0], native["InjectedStepOtherProvider"]], False)
    refused = poll(client, job, lambda s: s["terminal"], timings)
    assert refused["state"] == "failed" and not refused["summary"].get("changed", False), refused
    assert not refused["result"]["preflight"]["complete"], refused
    snapshots.append(refused)
    client.call("jobs.discard", jobId=job)
    assert client.call("session.get_dirty_state") == baseline
    for boundary in (lambda s: s["progress"]["detail"]["phase"] == "build-references" and
                     s["progress"]["detail"]["loadedFilesProcessed"] > 0,
                     lambda s: s["progress"]["detail"]["phase"] == "global-preflight" and
                     s["progress"]["detail"]["globalRecordsPlanned"] > 0,
                     lambda s: s["progress"]["detail"]["phase"] == "masters"):
        job = start(client, selected, False)
        partial = poll(client, job, boundary, timings)
        assert not partial["summary"].get("changed", False), partial
        snapshots.append(cancel(client, job, partial))
        assert client.call("session.get_dirty_state") == baseline
    job = start(client, selected)
    dry = poll(client, job, lambda s: s["terminal"], timings)
    assert dry["state"] == "succeeded" and dry["dryRun"] and dry["summary"]["planned"] == COUNT, dry
    snapshots.append(dry)
    assert client.call("session.get_dirty_state") == baseline
    job = start(client, selected, False)
    copied = poll(client, job, lambda s: s["progress"]["detail"]["phase"] == "remove-injected", timings)
    assert copied["result"]["records"][0]["preservationComplete"] and not copied["summary"].get("applied", 0), copied
    denied = client.request(json.dumps({"command": "session.save", "args": {"files": [PROVIDER]}}))
    assert denied["error"]["code"] == "job_busy", denied
    snapshots.append(cancel(client, job, copied))
    assert_loaded(client, set(), {0})
    # Copied-only cancellation requires explicit overwrite on retry.
    job = start(client, selected, False)
    conflict = poll(client, job, lambda s: s["terminal"], timings)
    assert conflict["state"] == "failed" and not conflict["summary"].get("changed", False), conflict
    snapshots.append(conflict)
    client.call("jobs.discard", jobId=job)
    job = start(client, selected, False, True)
    partial = poll(client, job, lambda s: s["summary"].get("applied", 0) == 1 and
                   s["progress"]["detail"]["phase"] == "select-record", timings)
    snapshots.append(cancel(client, job, partial))
    assert_loaded(client, {0}, {0})
    # Retry only still-injected sources; global preflight continues across both files.
    job = start(client, selected[1:], False)
    final = poll(client, job, lambda s: s["terminal"], timings)
    assert final["state"] == "succeeded" and final["summary"]["applied"] == COUNT - 1, final
    assert final["summary"]["requiresManualReview"] == 0, final
    assert {BASE, SECOND, PROVIDER} <= set(final["summary"]["dirtyFiles"]), final
    events = findings(client, job)
    assert [event["code"] for event in events].count("injected_cleanup_planned") == COUNT - 1, events
    assert [event["code"] for event in events].count("injected_cleanup_applied") == COUNT - 1, events
    assert all(not event["applied"] for event in events[:COUNT - 1]), events
    assert_loaded(client, set(range(COUNT)), set(range(COUNT)))
    snapshots.append(final)
    assert all((overlay / name).read_bytes() == blob for name, blob in before.items())
    (artifacts / "injected-step-report.json").write_text(json.dumps({"snapshots": snapshots,
        "pollSeconds": timings, "timingScope": "IPC plus native units; no latency guarantee"}, indent=2), encoding="utf-8")
    client.call("session.save", files=[BASE, SECOND, PROVIDER])
    client.call("session.flush")


def verify(client, overlay):
    assert_loaded(client, set(range(COUNT)), set(range(COUNT)))
    assert (overlay / OTHER).read_bytes() == fixtures()[OTHER]
    _, provider = disk_state((overlay / PROVIDER).read_bytes())
    for i in range(COUNT):
        name = f"InjectedStepRoot{i:03d}"
        _, source = disk_state((overlay / (BASE if i < FIRST_COUNT else SECOND)).read_bytes())
        assert source[name]["identity"] == provider[name]["identity"] == 0x1000 + i
        assert [struct.unpack_from("<I", value, 4)[0] for value in source[name]["fields"][b"LVLO"]] == [0x01000801]
        assert [struct.unpack_from("<I", value, 4)[0] for value in provider[name]["fields"][b"LVLO"]] == [0x01002000, 0x01000801]
    _, base = disk_state((overlay / BASE).read_bytes())
    assert [struct.unpack_from("<I", value, 4)[0] for value in base["InjectedStepOtherProvider"]["fields"][b"LVLO"]] == [0x01003000, 0x01000801]


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
