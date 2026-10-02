"""FO4 native delta scene; generate overlay, exercise, then fresh-process verify."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client, record, subrecord, plugin, read_keywords

MASTER = "AutomationDeltaMaster.esm"
BASE = "AutomationDeltaBaseline.esp"
COMPARE = "AutomationDeltaComparison.esp"
OUTPUT = "AutomationDeltaOutput.esu"


def keyword(name, identity, flags=0):
    return record(b"KYWD", subrecord(b"EDID", name.encode("ascii") + b"\0"), flags, identity)


def fixtures():
    base = keyword("DeltaIdentical", 0x02000800)
    base += keyword("DeltaFlagOnly", 0x02000801)
    base += keyword("DeltaOldPayload", 0x02000802)
    base += keyword("DeltaRemoved", 0x02000803)
    base += keyword("DeltaAlreadyDeleted", 0x02000804, 0x20)
    base += keyword("DeltaBaselineOverride", 0x01000800)
    newer = keyword("DeltaIdentical", 0x02000800)
    newer += keyword("DeltaFlagOnly", 0x02000801, 0x80000000)
    newer += keyword("DeltaNewPayload", 0x02000802)
    # This matches the oldest master, but differs from the selected baseline.
    newer += keyword("DeltaOldestValue", 0x01000800)
    newer += keyword("DeltaNewRecord", 0x02000900)
    masters = ["Fallout4.esm", MASTER]
    return {MASTER: plugin(["Fallout4.esm"], keyword("DeltaOldestValue", 0x01000800), True, 1),
            BASE: plugin(masters, base, record_count=6),
            COMPARE: plugin(masters, newer, record_count=5)}


def expected():
    return {"DeltaFlagOnly": 0x80000000, "DeltaNewPayload": 0,
            "DeltaRemoved": 0x20, "DeltaOldestValue": 0, "DeltaNewRecord": 0}


def listing(client, file):
    result = client.call("records.list", file=file, signature="KYWD", limit=50)
    assert not result["truncated"], result
    return {row["object"]["editorId"]: row["locator"] for row in result["records"]}


def verify(client):
    rows = listing(client, OUTPUT)
    assert set(rows) == set(expected()), rows
    for name, flags in expected().items():
        value = client.call("elements.get_value", **rows[name], path="Record Header\\Record Flags")
        assert int(value["values"]["nativeValue"]["value"]) & 0xFFFFFFFF == flags, (name, value)
    assert "DeltaBaselineOverride" in listing(client, BASE)
    assert "DeltaAlreadyDeleted" in listing(client, BASE)


def exercise(client, comparison):
    args = dict(sourceFile=BASE, comparePath=str(comparison.resolve()), outputFile=OUTPUT)
    before = client.call("session.get_dirty_state")
    original = listing(client, BASE)
    plan = client.call("patches.delta", **args)
    assert plan["complete"] and plan["dryRun"] and not plan["changed"], plan
    assert not plan["recordOutcomesAvailable"] and not plan["externalCopyCreated"] and not plan["loaded"], plan
    assert not Path(plan["outputPath"]).exists(), plan
    assert before == client.call("session.get_dirty_state")
    applied = client.call("patches.delta", **args, dryRun=False)
    assert applied["complete"] and applied["externalCopyCreated"] and applied["loaded"], applied
    assert applied["deletionMarkers"] == 1 and applied["itmRemoved"] == 1, applied
    assert applied["requiresSave"] and applied["changed"], applied
    assert set(read_keywords(Path(applied["outputPath"]).read_bytes())) == set(read_keywords(comparison.read_bytes()))
    assert listing(client, BASE) == original
    verify(client)
    revision = client.call("session.get_dirty_state")["mutationRevision"]
    refused = client.request(json.dumps({"command": "patches.delta", "args": {**args, "dryRun": False}}))
    assert not refused["ok"] and refused["error"]["code"] == "state_conflict", refused
    assert revision == client.call("session.get_dirty_state")["mutationRevision"]
    client.call("session.save", files=[OUTPUT])
    client.call("session.flush")


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
        for name, data in fixtures().items():
            with (args.overlay / name).open("xb") as stream:
                stream.write(data)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Live phases require --exe, --pid and --artifacts")
        client = Client(args.exe, args.pid, args.artifacts)
        if args.phase == "exercise":
            exercise(client, args.overlay / COMPARE)
        else:
            verify(client)


if __name__ == "__main__":
    main()
