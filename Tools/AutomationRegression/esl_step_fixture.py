"""Read-only retained ESL statistics and fresh unsaved-record acceptance in FO4.

Generate a disposable dedicated MO2 overlay. Load Fallout4.esm followed by BASE,
PATCH, CELL, HIGH, SPARSE, FRESH in that order; exercise needs edit consent for
one fresh-record setup. This runner changes only that fresh record in memory;
analysis never saves. Python tests do not execute native xEdit.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord
from row_fixture import keyword
from selective_step_fixture import group, records
from validation_step_fixture import findings
from hygiene_step_fixture import raw_headers

BASE = "AutomationEslStepBase.esm"
PATCH = "AutomationEslStepOverride.esp"
CELL = "AutomationEslStepCell.esp"
HIGH = "AutomationEslStepHigh.esp"
SPARSE = "AutomationEslStepSparse.esp"
FRESH = "AutomationEslStepFresh.esp"
COUNT = 5000
KIND = "plugin.esl.analyze"


def plugin(masters, groups, count, next_id, esm=False):
    body = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, next_id))
    for name in masters:
        body += subrecord(b"MAST", name.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    return record(b"TES4", body, int(esm)) + b"".join(groups)


def fixtures():
    keywords = b"".join(keyword(f"EslStepKeyword{i:04d}", 0x01000800 + i) for i in range(COUNT))
    cell = record(b"CELL", subrecord(b"EDID", b"EslStepNewCell\0") +
                  subrecord(b"DATA", b"\1\0"), form_id=0x02006000)
    cells = group(b"CELL", 0, group(6, 2, group(7, 3, cell)))  # 0x6000 = 24576.
    return {
        BASE: plugin(["Fallout4.esm"], [group(b"KYWD", 0, keywords)], COUNT, 0x800 + COUNT, True),
        PATCH: plugin(["Fallout4.esm", BASE], [group(b"KYWD", 0, keywords +
                      keyword("EslStepOwned", 0x02000A00))], COUNT + 1, 0xA01),
        CELL: plugin(["Fallout4.esm", BASE], [cells], 1, 0x6001),
        HIGH: plugin(["Fallout4.esm"], [group(b"KYWD", 0, keyword("EslStepHigh", 0x01010000))], 1, 0x10001),
        SPARSE: plugin(["Fallout4.esm"], [group(b"KYWD", 0, keyword("EslStepSparse", 0x0100FF00))], 1, 0xFF01),
        FRESH: plugin(["Fallout4.esm"], [], 0, 0x800),
    }


def validate_state(state):
    detail, progress = state["progress"]["detail"], state["progress"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert 0 <= detail["totalWorkUnits"] <= detail["totalWorkLimit"] == 1000000, state
    assert 0 <= detail["retainedDepth"] <= detail["depthLimit"] == 64, state
    assert 0 <= detail["newRecordCount"] <= detail["seenRecordLimit"] == 100000, state
    assert 0 <= detail["objectIdProbes"] <= detail["objectIdProbeLimit"] <= 65535, state
    assert detail["softBudgetMs"] == 20 and not detail["nativeCallsPreemptible"], state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    assert not state["summary"]["changed"] and not state["summary"]["requiresSave"], state
    rows = state["result"]["files"]
    completed = [row for row in rows if row["complete"]]
    assert len(completed) == progress["completed"], state
    assert state["summary"].get("eligible", 0) == sum(row["eligible"] for row in completed), state
    assert state["summary"].get("ineligible", 0) == sum(not row["eligible"] for row in completed), state
    for row in rows:
        if row["complete"]:
            assert row["statsComplete"], row
        else:
            assert "eligible" not in row and "requiresCompact" not in row, row
    if state["terminal"]:
        assert not state["cursorRetained"], state
    if state["state"] == "succeeded":
        assert not progress["remaining"] and not detail["retainedDepth"], state


def start(client, files):
    return client.call("jobs.start", kind=KIND, target={"files": files})["jobId"]


def poll(client, job, predicate, timings):
    for _ in range(20000):
        began = time.monotonic()
        state = client.call("jobs.get", jobId=job)
        timings.append(time.monotonic() - began)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("ESL analysis did not reach requested phase")


def cancel(client, job, partial):
    before = findings(client, job)
    state = client.call("jobs.cancel", jobId=job)
    validate_state(state)
    assert state["state"] == "canceled" and state["progress"] == partial["progress"], state
    assert state["result"] == partial["result"] and findings(client, job) == before
    assert client.call("jobs.get", jobId=job) == state
    client.call("jobs.discard", jobId=job)
    return state


def exercise(client, overlay, artifacts):
    before = {name: (overlay / name).read_bytes() for name in fixtures()}
    assert not records(client, FRESH, "KYWD")
    client.call("records.create", targetFile=FRESH, signature="KYWD", editorId="EslStepUnsaved")
    fresh = records(client, FRESH, "KYWD")
    assert len(fresh) == 1 and fresh[0]["object"]["editorId"] == "EslStepUnsaved", fresh
    fresh_id = int(fresh[0]["locator"]["formId"], 16) & 0xFFFFFF
    baseline = client.call("session.get_dirty_state")
    timings, snapshots = [], []
    for files in ([BASE, "Missing.esp"], [PATCH, PATCH], [], [BASE] * 257):
        reply = client.request(json.dumps({"command": "jobs.start", "args": {
            "kind": KIND, "target": {"files": files}}}))
        assert not reply["ok"], reply
    for file, phase in ((BASE, "file-tree"), (PATCH, "visible-groups"), (SPARSE, "object-id-fallback")):
        job = start(client, [file])
        partial = poll(client, job, lambda s: s["progress"]["detail"]["phase"] == phase and
                       s["progress"]["detail"]["totalWorkUnits"] > 128 and
                       (phase != "object-id-fallback" or s["progress"]["detail"]["objectIdProbes"] > 0), timings)
        assert not partial["terminal"] and not partial["result"]["files"][0]["complete"], partial
        snapshots.append(cancel(client, job, partial))
        assert client.call("session.get_dirty_state") == baseline
    # Preserve findings from a completed file while the next file remains pending.
    job = start(client, [BASE, SPARSE])
    first = poll(client, job, lambda s: s["progress"]["completed"] == 1, timings)
    assert findings(client, job) and not first["terminal"], first
    snapshots.append(cancel(client, job, first))
    job = start(client, list(fixtures()))
    final = poll(client, job, lambda s: s["terminal"], timings)
    assert final["state"] == "succeeded" and final["summary"]["eligible"] == 2, final
    expected = {BASE: (COUNT, 0x800, 0x800 + COUNT - 1, False),
                PATCH: (1, 0xA00, 0xA00, True), CELL: (1, 0x6000, 0x6000, False),
                HIGH: (1, 0x10000, 0x10000, False), SPARSE: (1, 0xFF00, 0xFF00, False),
                FRESH: (1, fresh_id, fresh_id, True)}
    for row in final["result"]["files"]:
        observed = (row["newRecordCount"], int(row["minObjectId"], 16), int(row["maxObjectId"], 16), row["eligible"])
        assert observed == expected[row["fileName"]], (row, expected[row["fileName"]])
        codes = {item["code"] for item in row["blockers"] + row["risks"]}
        if row["fileName"] == BASE:
            assert "too_many_new_records_for_light" in codes, row
        if row["fileName"] == CELL:
            assert "new_cell_record_risk" in codes, row
        assert row["requiresCompact"] == (not row["eligible"]), row
    snapshots.append(final)
    assert client.call("session.get_dirty_state") == baseline
    assert all((overlay / name).read_bytes() == blob for name, blob in before.items())
    (artifacts / "esl-steps.json").write_text(json.dumps({"snapshots": snapshots,
        "pollSeconds": timings, "strictLatencyGuaranteeTested": False}, indent=2), encoding="utf-8")


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
