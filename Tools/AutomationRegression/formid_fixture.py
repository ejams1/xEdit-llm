"""Generate FO4 FormID/reference fixtures; run exercise, then fresh-process verify."""
import argparse
import json
from pathlib import Path
import struct
from itm_fixture import Client, record, subrecord
from circular_fixture import leveled_record

MASTER = "AutomationFormIdMaster.esm"
PLUGIN = "AutomationFormIdPatch.esp"


def plugin(masters, records, count, esm=False):
    header = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0x900))
    for master in masters:
        header += subrecord(b"MAST", master.encode("ascii") + b"\0")
        header += subrecord(b"DATA", b"\0" * 8)
    group = struct.pack("<4sI4sIHHHH", b"GRUP", len(records) + 24,
                        b"LVLI", 0, 0, 0, 0, 0) + records
    return record(b"TES4", header, int(esm)) + group


def fixtures():
    master = leveled_record(b"LVLI", "AutoTargetB", 0x01000800)
    patch = leveled_record(b"LVLI", "AutoTargetA", 0x02000801)
    patch += leveled_record(b"LVLI", "AutoRefC", 0x02000802, 0x02000801)
    patch += leveled_record(b"LVLI", "AutoRefD", 0x02000803, 0x02000801)
    return {MASTER: plugin(["Fallout4.esm"], master, 1, True),
            PLUGIN: plugin(["Fallout4.esm", MASTER], patch, 3)}


def discover(client, file):
    page = client.call("records.list", file=file, signature="LVLI", limit=50)
    assert not page["truncated"], page
    return {item["object"]["editorId"]: item["locator"]["formId"]
            for item in page["records"]}


def assert_links(client, records, target):
    for name in ("AutoRefC", "AutoRefD"):
        result = client.call("records.references", file=PLUGIN,
                             formId=records[name], limit=50)
        ids = {item["locator"]["formId"].upper() for item in result["hits"]}
        assert target.upper() in ids, (name, target, result)


def replace(client, old, new, dry_run):
    return client.call("references.replace", scopeFiles=[PLUGIN],
                       mappings=[{"oldFormId": old, "newFormId": new}], dryRun=dry_run)


def exercise(client):
    records = discover(client, PLUGIN)
    target_b = discover(client, MASTER)["AutoTargetB"]
    old = records["AutoTargetA"]
    revision = client.call("session.get_dirty_state")["mutationRevision"]
    plan = replace(client, old, target_b, True)
    assert plan["complete"] and not plan["changed"], plan
    assert plan["mappings"][0]["inScopeReferrers"] == 2, plan
    assert client.call("session.get_dirty_state")["mutationRevision"] == revision
    assert_links(client, records, old)
    applied = replace(client, old, target_b, False)
    assert applied["complete"] and applied["mappings"][0]["changedRecords"] == 2, applied
    assert len(applied["mappings"][0]["records"]) == 2, applied
    assert_links(client, records, target_b)
    assert replace(client, target_b, old, False)["complete"]

    # A collision must reject before changing any plugin; compare state and links.
    before = client.call("session.get_dirty_state")
    denied = client.request(json.dumps({"command": "formids.change", "args": {
        "file": PLUGIN, "formId": old, "newFormId": records["AutoRefC"], "dryRun": False}}))
    assert denied["error"]["code"] == "formid_collision", denied
    assert client.call("session.get_dirty_state")["mutationRevision"] == before["mutationRevision"]
    assert_links(client, records, old)
    new = old[:-6] + "000900"
    planned = client.call("formids.change", file=PLUGIN, formId=old, newFormId=new)
    assert planned["dryRun"] and not planned["changed"], planned
    changed = client.call("formids.change", file=PLUGIN, formId=old, newFormId=new, dryRun=False)
    assert changed["complete"] and changed["completed"] == 1, changed
    records = discover(client, PLUGIN)
    assert records["AutoTargetA"].upper() == new.upper(), records
    assert_links(client, records, new)
    renumbered = client.call("formids.renumber", file=PLUGIN,
                             formIds=[records["AutoRefC"]],
                             startFormId=new[:-6] + "000A00", dryRun=False)
    assert renumbered["complete"], renumbered
    injected = client.call("formids.inject", file=PLUGIN, masterFile=MASTER,
                           formIds=[new], preserveObjectIds=True, dryRun=False)
    assert injected["complete"], injected
    verify(client)
    client.call("session.save", files=[PLUGIN])
    client.call("session.flush")


def verify(client):
    records = discover(client, PLUGIN)
    master_id = discover(client, MASTER)["AutoTargetB"]
    assert records["AutoTargetA"].upper() == (master_id[:-6] + "000900").upper(), records
    assert records["AutoRefC"][-6:].upper() == "000A00", records
    assert_links(client, records, records["AutoTargetA"])


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
        (exercise if args.phase == "exercise" else verify)(client)


if __name__ == "__main__":
    main()
