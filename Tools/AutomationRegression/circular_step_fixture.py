"""Generate and exercise retained circular graph checks on disposable FO4 files.

Use a fresh MO2 overlay/process for each variant; native compilation and execution
are separate from Python fixture-integrity tests.
"""
import argparse
import json
from pathlib import Path
import struct

from circular_fixture import leveled_record, SIGNATURES
from itm_fixture import Client, record, subrecord
from pagination_fixture import drain
from validation_step_fixture import advance, finish, findings, validate_progress

PLUGIN = "AutomationCircularSteps.esp"
MASTER = "AutomationCircularStepMaster.esm"
OVERRIDE = "AutomationCircularStepWinner.esp"
CHAIN_COUNT = 513
LONG_CYCLE_COUNT = 400
DEPTH_CAPACITY_COUNT = 1100
KIND = "validation.circular_leveled_lists"


def make_plugin(masters, groups, count, next_id, esm=False):
    header = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, next_id))
    for master in masters:
        header += subrecord(b"MAST", master.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    body = b"".join(struct.pack("<4sI4sIHHHH", b"GRUP", len(records) + 24,
                                signature, 0, 0, 0, 0, 0) + records
                    for signature, records in groups)
    return record(b"TES4", header, flags=int(esm)) + body


def fixture_bytes(depth_capacity=False):
    chain_count = DEPTH_CAPACITY_COUNT if depth_capacity else CHAIN_COUNT
    groups = []
    for index, signature in enumerate(SIGNATURES):
        first = 0x01000800 + index * 2
        records = leveled_record(signature, f"AutoStep{signature.decode()}A", first, first + 1)
        records += leveled_record(signature, f"AutoStep{signature.decode()}B", first + 1, first)
        if signature == b"LVLI":
            for node in range(chain_count):
                target = 0x01001000 + node + 1 if node < chain_count - 1 else None
                records += leveled_record(signature, f"AutoStepChain{node:04d}", 0x01001000 + node, target)
            if not depth_capacity:
                for node in range(LONG_CYCLE_COUNT):
                    target = 0x01002000 + (node + 1) % LONG_CYCLE_COUNT
                    records += leveled_record(signature, f"AutoStepLongCycle{node:04d}", 0x01002000 + node, target)
        groups.append((signature, records))
    count = 6 + chain_count + (0 if depth_capacity else LONG_CYCLE_COUNT)
    base = b"".join(leveled_record(b"LVLI", name, 0x01003000 + node, 0x01003000 + target)
                    for node, name, target in (
                        (0, "AutoStepBrokenA", 1), (1, "AutoStepBrokenB", 0),
                        (2, "AutoStepWinnerC", 3), (3, "AutoStepWinnerD", 2)))
    winner = leveled_record(b"LVLI", "AutoStepBrokenBWinner", 0x01003001)
    winner += leveled_record(b"LVLI", "AutoStepWinnerCOverride", 0x01003002, 0x01003003)
    return {
        PLUGIN: make_plugin(["Fallout4.esm"], groups, count, 0x3000),
        MASTER: make_plugin(["Fallout4.esm"], [(b"LVLI", base)], 4, 0x3004, True),
        OVERRIDE: make_plugin(["Fallout4.esm", MASTER], [(b"LVLI", winner)], 2, 0x800),
    }


def read_lists(data):
    """Decode persisted identities/edges independently of daemon snapshots."""
    observed = {}

    def visit(start, end):
        while start < end:
            signature, size = struct.unpack_from("<4sI", data, start)
            if signature == b"GRUP":
                visit(start + 24, start + size)
                start += size
                continue
            pos, stop = start + 24, start + 24 + size
            form_id = struct.unpack_from("<I", data, start + 12)[0]
            name, edges = None, []
            while pos < stop:
                sub, length = struct.unpack_from("<4sH", data, pos)
                payload = data[pos + 6:pos + 6 + length]
                if sub == b"EDID":
                    name = payload.rstrip(b"\0").decode()
                if sub == b"LVLO":
                    edges.append(struct.unpack_from("<I", payload, 4)[0])
                pos += 6 + length
            assert pos == stop, "Malformed fixture subrecord boundary"
            if signature in SIGNATURES:
                assert name is not None and form_id not in observed
                observed[form_id] = {"name": name, "signature": signature.decode(), "edges": edges}
            start = stop
        assert start == end, "Malformed fixture record boundary"

    visit(0, len(data))
    return observed


def cycles(values):
    return [finding for finding in values if finding["code"] == "circular_leveled_list"]


def locator_identity(locator):
    return (locator["file"], locator["formId"].replace(" ", ""))


def exercise(client, artifacts, depth_capacity=False):
    before = client.call("session.get_dirty_state")
    timings = []
    names = {}
    for signature in SIGNATURES:
        records, _ = drain(client, "records.list", "records",
                           {"file": PLUGIN, "signature": signature.decode(), "limit": 500})
        names.update({entry["object"]["editorId"]: locator_identity(entry["locator"])
                      for entry in records})
    started = client.call("jobs.start", kind=KIND, target={"files": [PLUGIN]})
    job_id = started["jobId"]
    for _ in range(1000):
        partial = advance(client, job_id, timings)
        assert partial["state"] == "running" and partial["progress"]["completed"] == 0, partial
        detail = partial["progress"]["detail"]
        assert not detail["usesSharedNativeTags"] and detail["depthLimit"] == 1024, partial
        if detail["phase"] == "graph" and detail["retainedDepth"] >= 64 and partial["findingCount"] > 0:
            break
    else:
        raise AssertionError("No retained deep graph with prior findings was exposed")
    retained = findings(client, job_id)
    denied = client.request(json.dumps({"command": "session.save", "args": {}}))
    assert denied["error"]["code"] == "job_busy", denied
    client.call("records.list", file=PLUGIN, signature="LVLI", limit=37)
    canceled = client.call("jobs.cancel", jobId=job_id)
    validate_progress(canceled)
    assert canceled["state"] == "canceled" and canceled["progress"] == partial["progress"], canceled
    assert not canceled["result"]["files"][0]["complete"], canceled
    assert findings(client, job_id) == retained
    assert client.call("jobs.get", jobId=job_id) == canceled
    client.call("jobs.discard", jobId=job_id)

    restarted = client.call("jobs.start", kind=KIND, target={"files": [PLUGIN]})
    final = finish(client, restarted["jobId"], timings)
    observed = findings(client, restarted["jobId"])
    assert observed[:len(retained)] == retained
    if depth_capacity:
        assert final["state"] == "failed" and final["failure"]["code"] == "job_capacity", final
        assert final["progress"]["completed"] == 0 and observed, final
        assert not final["result"]["files"][0]["complete"], final
    else:
        assert final["state"] == "succeeded", final
        actual = cycles(observed)
        assert len(actual) == 4 and final["summary"]["cycleCount"] == 4, final
        expected_roots = {names[f"AutoStep{sig.decode()}A"] for sig in SIGNATURES}
        expected_roots.add(names["AutoStepLongCycle0000"])
        assert {locator_identity(f["target"]) for f in actual} == expected_roots, actual
        assert {f["target"]["signature"] for f in actual} == {"LVLI", "LVLN", "LVSP"}, actual
        long_cycle = [f for f in actual if f["cyclePathLength"] == LONG_CYCLE_COUNT + 1]
        assert len(long_cycle) == 1, actual
        long_cycle = long_cycle[0]
        assert long_cycle["cyclePathTruncated"] and long_cycle["messageTruncated"], long_cycle
        assert len(long_cycle["cyclePath"]) == len(long_cycle["cyclePathNames"]) == 100, long_cycle
        assert long_cycle["originalMessageCharacters"] > 4096, long_cycle
        assert [locator_identity(node) for node in long_cycle["cyclePath"]] == [
            names[f"AutoStepLongCycle{index:04d}"] for index in range(100)], long_cycle
        for finding in actual:
            if finding is long_cycle:
                continue
            signature = finding["target"]["signature"]
            assert [locator_identity(node) for node in finding["cyclePath"]] == [
                names[f"AutoStep{signature}A"], names[f"AutoStep{signature}B"],
                names[f"AutoStep{signature}A"]], finding
        assert all("AutoStepChain" not in f["message"] for f in actual), actual
        assert final["summary"]["checkedRecords"] == 6 + CHAIN_COUNT + LONG_CYCLE_COUNT, final
        assert final["result"]["files"][0]["visitedRecords"] == final["summary"]["checkedRecords"], final
    assert len(observed) == final["findingCount"], final
    client.call("jobs.discard", jobId=restarted["jobId"])

    # The master has two cycles on disk. A later winning B breaks one; a later
    # winning C preserves the other and must own the returned root locator.
    cross = client.call("jobs.start", kind=KIND, target={"files": [MASTER]})
    cross = finish(client, cross["jobId"], timings)
    cross_findings = cycles(findings(client, cross["jobId"]))
    assert cross["state"] == "succeeded" and cross["summary"]["cycleCount"] == 1, cross
    assert len(cross_findings) == 1 and cross_findings[0]["target"]["file"] == OVERRIDE, cross_findings
    path = cross_findings[0]["cyclePath"]
    assert [node["file"] for node in path] == [OVERRIDE, MASTER, OVERRIDE], path
    assert path[0] == path[-1], path
    assert "AutoStepWinnerCOverride" in cross_findings[0]["message"], cross_findings
    assert "AutoStepBroken" not in cross_findings[0]["message"], cross_findings
    client.call("jobs.discard", jobId=cross["jobId"])
    after = client.call("session.get_dirty_state")
    assert before == after, (before, after)
    report = {"depthCapacity": depth_capacity, "jobs": [final, cross],
              "pollSeconds": timings, "maxPollSeconds": max(timings),
              "dirtyBefore": before, "dirtyAfter": after,
              "timingIncludesClientProcessAndIPC": True, "hardLatencyGuaranteeTested": False}
    (artifacts / "circular-steps.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("generate", "exercise"))
    parser.add_argument("--depth-capacity", action="store_true")
    parser.add_argument("--overlay", type=Path)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        if args.overlay is None:
            parser.error("Generate requires --overlay (a fresh MO2 mod directory)")
        args.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixture_bytes(args.depth_capacity).items():
            with (args.overlay / name).open("xb") as stream:
                stream.write(data)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Exercise requires --exe, --pid and --artifacts")
        report = exercise(Client(args.exe, args.pid, args.artifacts), args.artifacts, args.depth_capacity)
        print(f"Circular cursor checks passed; longest client poll {report['maxPollSeconds']:.3f}s")


if __name__ == "__main__":
    main()
