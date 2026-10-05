"""Combined-cleaning master scan cancellation and direct-native parity acceptance.

Use hygiene_step_fixture.py's fresh FO4 overlay and exact load order. Run this
runner INSTEAD OF hygiene_step_fixture exercise/verify on a fresh overlay.
Native Delphi/MO2 execution is required; Python tests only check assertions.
"""
import argparse
import json
from pathlib import Path
import time

from itm_fixture import Client
from row_fixture import disk_state
from selective_step_fixture import records
from validation_step_fixture import findings
import hygiene_step_fixture as source
from combined_step_fixture import validate_state as validate_combined

SORT_KIND = "cleaning.sort_and_clean_masters"
AUTO_KIND = "cleaning.quick_auto_clean"


def validate_state(state):
    validate_combined(state)
    detail = state["progress"]["detail"]
    assert 0 <= detail["masterScanWorkUnits"] <= detail["masterScanWorkLimit"] == 1000000, state
    assert 0 <= detail["masterRetainedDepth"] <= detail["masterDepthLimit"] == 128, state
    assert detail["masterNativeUsageCalls"] <= detail["masterScanWorkUnits"], state
    if state["state"] == "succeeded":
        assert detail["masterRetainedDepth"] == 0, state
        if not state["dryRun"]:
            row = state["result"]["files"][0]
            assert row["operations"]["cleanMasters"]["scanComplete"], state


def start(client, kind, file, dry):
    return client.call("jobs.start", kind=kind, target={"files": [file]}, dryRun=dry)["jobId"]


def poll(client, job, predicate, timings):
    for _ in range(20000):
        began = time.monotonic()
        state = client.call("jobs.get", jobId=job)
        timings.append(time.monotonic() - began)
        validate_state(state)
        if predicate(state):
            return state
        assert not state["terminal"], state
    raise AssertionError("Combined master scan did not reach requested phase")


def cancel(client, job, partial):
    before = findings(client, job)
    state = client.call("jobs.cancel", jobId=job)
    validate_state(state)
    assert state["state"] == "canceled" and state["progress"] == partial["progress"], state
    assert state["result"] == partial["result"] and findings(client, job) == before, state
    assert client.call("jobs.get", jobId=job) == state
    client.call("jobs.discard", jobId=job)
    return state


def exercise(client, overlay, artifacts):
    initial = client.call("session.get_dirty_state")
    assert not initial["dirty"], initial
    timings, states = [], []
    for kind, file in ((SORT_KIND, source.STEPPED), (AUTO_KIND, source.CANCELED)):
        dry_job = start(client, kind, file, True)
        dry = poll(client, dry_job, lambda s: s["terminal"], timings)
        assert dry["state"] == "succeeded" and not dry["progress"]["detail"]["masterScanWorkUnits"], dry
        states.append(dry)
        assert client.call("session.get_dirty_state") == initial
        # Fresh cursor each time; cancellation after scan cannot enter remapping.
        for boundary in (lambda s: s["progress"]["detail"]["phase"] == "scan-masters" and
                         s["progress"]["detail"]["masterNativeUsageCalls"] > 0,
                         lambda s: s["progress"]["detail"]["phase"] == "apply-clean-masters"):
            job = start(client, kind, file, False)
            partial = poll(client, job, boundary, timings)
            op = partial["result"]["files"][0]["operations"]["cleanMasters"]
            assert op["planned"] == 1 and not op["applied"] and not op["complete"], op
            assert source.masters(client, file) == source.INITIAL
            assert not partial["summary"]["applied"], partial
            states.append(cancel(client, job, partial))
            assert client.call("session.get_dirty_state") == initial
            source.assert_loaded(client, file, source.INITIAL)
    direct = client.call("files.clean_masters", file=source.DIRECT)
    assert direct["removedMasters"] == [source.UNUSED], direct
    for kind, file in ((SORT_KIND, source.STEPPED), (AUTO_KIND, source.CANCELED)):
        job = start(client, kind, file, False)
        final = poll(client, job, lambda s: s["terminal"], timings)
        assert final["state"] == "succeeded", final
        master = final["result"]["files"][0]["operations"]["cleanMasters"]
        assert master["scanComplete"] and master["planned"] == master["applied"] == 1, master
        assert source.masters(client, file) == source.FINAL
        assert source.masters(client, file) == source.masters(client, source.DIRECT)
        if kind == AUTO_KIND:
            rows = {row["operation"]: row for row in final["result"]["files"]}
            assert rows["remove_itm"]["applied"] == source.COUNT, rows
            assert rows["undelete_and_disable_refs"]["applied"] == 0, rows
            assert not records(client, file, "KYWD")
        else:
            source.assert_loaded(client, file, source.FINAL)
        states.append(final)
    for file, blob in source.fixtures().items():
        assert (overlay / file).read_bytes() == blob, file
    (artifacts / "combined-master-scans.json").write_text(json.dumps({
        "states": states, "pollSeconds": timings,
        "strictLatencyGuaranteeTested": False}, indent=2), encoding="utf-8")
    client.call("session.save", files=[source.STEPPED, source.DIRECT, source.CANCELED])
    client.call("session.flush")


def verify(client, overlay):
    for name in (source.BASE, source.LABEL, source.UNUSED):
        assert (overlay / name).read_bytes() == source.fixtures()[name], name
    for name in (source.STEPPED, source.DIRECT):
        source.assert_loaded(client, name, source.FINAL)
    assert disk_state((overlay / source.STEPPED).read_bytes()) == disk_state((overlay / source.DIRECT).read_bytes())
    for name in (source.STEPPED, source.DIRECT, source.CANCELED):
        masters, rows = disk_state((overlay / name).read_bytes())
        assert masters == source.FINAL, name
        assert [identity for sig, identity in source.raw_headers((overlay / name).read_bytes())[0]
                if sig == b"FLST"] == [0x03006000], name
    assert source.masters(client, source.CANCELED) == source.FINAL
    assert not records(client, source.CANCELED, "KYWD")
    assert set(disk_state((overlay / source.CANCELED).read_bytes())[1]) == {"HygieneOwnList"}
    links = client.call("records.references", **records(client, source.CANCELED, "FLST")[0]["locator"])
    assert links["complete"] and {row["object"]["editorId"] for row in links["hits"]} == {
        "HygieneKeyword0000", "HygieneKeyword2199"}, links


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
        for name, blob in source.fixtures().items():
            with (args.overlay / name).open("xb") as output:
                output.write(blob)
    else:
        if not args.exe or not args.pid or not args.artifacts:
            parser.error("Live phases require --exe, --pid and --artifacts")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        client = Client(args.exe, args.pid, args.artifacts)
        if args.phase == "exercise":
            exercise(client, args.overlay, args.artifacts)
        else:
            verify(client, args.overlay)


if __name__ == "__main__":
    main()
