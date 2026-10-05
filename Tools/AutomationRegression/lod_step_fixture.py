"""Skyrim native LOD boundary plus retained output-inventory acceptance.

The large inventories contain explicitly injected test witnesses, not generated
LOD. Original lod_fixture exercise/verify checks actual LST/BTT/DDS outputs.
"""
import argparse
import json
from pathlib import Path
import time

from itm_fixture import Client
from copy_modes_fixture import discover
import lod_fixture as original

COUNT = 400
ROOTS = ("OutputInventoryCancel", "OutputInventoryRetry", "OutputInventoryCap",
         "OutputInventoryNativeFailure", "OutputInventoryTwoWorlds")
OLD_ROOTS = ("OutputDry", "OutputTrees", "OutputSplit", "OutputFallback", "OutputMalformed",
             "OutputPermuted", "OutputDuplicate", "OutputEmpty", "OutputCancel")


def witnesses(root, count=COUNT):
    result = {}
    for i in range(count):
        path = root / "InventoryWitness" / f"Witness{i:04d}.bin"
        path.parent.mkdir(parents=True, exist_ok=True)
        blob = f"INVENTORY TEST WITNESS {i}\n".encode()
        with path.open("xb") as stream:
            stream.write(blob)
        result[str(path.relative_to(root)).replace("/", "\\")] = len(blob)
    return result


def validate_state(state):
    progress, rows = state["progress"], state["result"]["worldspaces"]
    detail = progress["detail"]
    assert 0 <= detail["lastWorkUnits"] <= detail["workLimit"] == 128, state
    assert detail["softBudgetMs"] == 20 and not detail["nativeCallsPreemptible"], state
    assert 0 <= detail["nativeUnits"] <= detail["nativeUnitLimit"] == 1, state
    assert progress["remaining"] == progress["total"] - progress["completed"], state
    assert sum(row["complete"] for row in rows) == progress["completed"], state
    assert state["summary"]["worldspaceCount"] == len(rows), state
    assert state["summary"]["completedWorldspaces"] == progress["completed"], state
    assert state["findingsComplete"] == (state["state"] == "succeeded"), state
    for row in rows:
        artifacts = row["artifacts"]
        assert row["generatedFiles"] == sum(not item["scratch"] for item in artifacts), row
        assert len({item["path"] for item in artifacts}) == len(artifacts), row
        if row["complete"] and not state["dryRun"]:
            assert row["nativeComplete"] and row["inventoryComplete"], row
    if "inventory" in detail:
        inventory = detail["inventory"]
        assert 0 <= inventory["workUnits"] <= inventory["workLimit"] == 16384, state
        assert 0 <= inventory["artifactCount"] <= inventory["fileLimit"] == 1024, state
        assert 0 <= inventory["artifactBytes"] <= inventory["byteLimit"] == 262144, state
        assert 1 <= inventory["directoriesSeen"] <= inventory["directoryLimit"] == 256, state
    if state["terminal"]:
        assert not state["cursorRetained"], state


def start(client, worlds, root, operation="generate"):
    return client.call("jobs.start", kind="lod.generate", dryRun=False, target={"worldspaces": worlds},
                       options={"outputRoot": str(root.resolve()), "operation": operation,
                                "objects": False, "trees": operation == "generate"})["jobId"]


def poll(client, job, predicate, timings):
    for _ in range(20000):
        began = time.monotonic()
        state = client.call("jobs.get", jobId=job)
        timings.append(time.monotonic() - began)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("LOD job did not reach requested boundary")


def cancel(client, job, partial):
    state = client.call("jobs.cancel", jobId=job)
    validate_state(state)
    assert state["state"] == "canceled" and state["summary"]["partialChanges"], state
    assert state["result"] == partial["result"] and state["progress"] == partial["progress"], state
    assert client.call("jobs.get", jobId=job) == state
    client.call("jobs.discard", jobId=job)
    return state


def exercise(client, overlay, artifacts):
    # Existing independent semantic output checks remain authoritative.
    original.exercise(client, overlay)
    baseline = client.call("session.get_dirty_state")
    plugin = (overlay / original.PLUGIN).read_bytes()
    worlds = discover(client, original.PLUGIN, "WRLD")
    timings, snapshots = [], []
    job = start(client, [worlds[original.WORLD]], overlay / ROOTS[0])
    native = poll(client, job, lambda s: s["progress"]["detail"]["phase"] == "output-inventory", timings)
    assert native["progress"]["completed"] == 0 and native["result"]["worldspaces"][0]["nativeComplete"], native
    assert not native["result"]["worldspaces"][0]["inventoryComplete"], native
    root = overlay / ROOTS[0] / original.WORLD
    expected = witnesses(root)
    partial = poll(client, job, lambda s: s["progress"]["detail"]["inventory"]["artifactCount"] > 20 and
                   not s["progress"]["detail"]["inventory"]["complete"], timings)
    snapshots.append(cancel(client, job, partial))
    assert all((root / name).read_bytes() == f"INVENTORY TEST WITNESS {i}\n".encode()
               for i, name in enumerate(expected))
    # Fresh output root is required after a canceled world already wrote output.
    options = {"outputRoot": str((overlay / ROOTS[0]).resolve()), "objects": False, "trees": True}
    refused = client.request(json.dumps({"command": "jobs.start", "args": {"kind": "lod.generate",
        "dryRun": False, "target": {"worldspaces": [worlds[original.WORLD]]}, "options": options}}))
    assert not refused["ok"] and refused["error"]["code"] == "state_conflict", refused
    job = start(client, [worlds[original.WORLD]], overlay / ROOTS[1])
    poll(client, job, lambda s: s["progress"]["detail"]["phase"] == "output-inventory", timings)
    expected = witnesses(overlay / ROOTS[1] / original.WORLD)
    complete = poll(client, job, lambda s: s["terminal"], timings)
    assert complete["state"] == "succeeded", complete
    indexed = {item["path"]: item["bytes"] for item in complete["result"]["worldspaces"][0]["artifacts"]}
    assert all(indexed.get(path) == size for path, size in expected.items()), indexed
    snapshots.append(complete)
    client.call("jobs.discard", jobId=job)
    job = start(client, [worlds[original.WORLD]], overlay / ROOTS[2])
    poll(client, job, lambda s: s["progress"]["detail"]["phase"] == "output-inventory", timings)
    witnesses(overlay / ROOTS[2] / original.WORLD, 1025)
    failed = poll(client, job, lambda s: s["terminal"], timings)
    row = failed["result"]["worldspaces"][0]
    assert failed["state"] == "failed" and failed["failure"]["code"] == "export_capacity", failed
    assert row["inventoryTruncated"] and not row["inventoryComplete"] and len(row["artifacts"]) == 1024, failed
    snapshots.append(failed)
    client.call("jobs.discard", jobId=job)
    job = start(client, [worlds[original.BAD]], overlay / ROOTS[3], "splitAtlas")
    native = poll(client, job, lambda s: s["progress"]["detail"]["phase"] == "output-inventory", timings)
    assert native["progress"]["detail"]["nativeFailurePending"], native
    assert "LST" in native["result"]["worldspaces"][0]["nativeFailure"]["message"], native
    witnesses(overlay / ROOTS[3] / original.BAD)
    partial = poll(client, job, lambda s: s["progress"]["detail"]["inventory"]["artifactCount"] > 20, timings)
    snapshots.append(cancel(client, job, partial))
    job = start(client, [worlds[original.WORLD], worlds[original.EMPTY]], overlay / ROOTS[4])
    final = poll(client, job, lambda s: s["terminal"], timings)
    assert final["state"] == "succeeded" and final["summary"]["worldspaceCount"] == 2, final
    snapshots.append(final)
    assert client.call("session.get_dirty_state") == baseline
    assert (overlay / original.PLUGIN).read_bytes() == plugin
    (artifacts / "lod-step-report.json").write_text(json.dumps({"snapshots": snapshots, "pollSeconds": timings,
        "timingScope": "IPC plus indivisible pipeline/tool wait; no latency guarantee",
        "witnessesAreGeneratedLOD": False}, indent=2), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("generate", "exercise", "verify"))
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        for name, blob in original.fixtures().items():
            target = args.overlay / name
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("xb") as stream:
                stream.write(blob)
        for name in (*OLD_ROOTS, *ROOTS):
            (args.overlay / name).mkdir()
    elif args.phase == "verify":
        original.verify(args.overlay)
    else:
        if not args.exe or not args.pid or not args.artifacts:
            parser.error("exercise requires --exe, --pid and --artifacts")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        exercise(Client(args.exe, args.pid, args.artifacts), args.overlay, args.artifacts)


if __name__ == "__main__":
    main()
