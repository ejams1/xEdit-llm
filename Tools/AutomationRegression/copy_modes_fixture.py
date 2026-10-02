"""FO4 wrapper/spawn and FO3 idle-copy acceptance; relaunch for verify after exercise."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct
from itm_fixture import Client, record, subrecord
from circular_fixture import leveled_record
from formid_fixture import plugin

SOURCE = "AutomationCopySource.esm"
WRAPPER = "AutomationWrapper.esp"
SPAWN = "AutomationSpawn.esp"
IDLES = "AutomationIdles.esm"
WINNER = "AutomationIdleWinner.esp"
COPIES = "AutomationIdleCopies.esp"


def leveled_source():
    target = leveled_record(b"LVLI", "AutoCopyTarget", 0x01000800)
    body = subrecord(b"EDID", b"AutoCopySource\0") + subrecord(b"OBND", b"\0" * 12)
    body += subrecord(b"LVLD", b"\0") + subrecord(b"LVLF", b"\0")
    body += subrecord(b"LLCT", b"\1")
    body += subrecord(b"LVLO", struct.pack("<HHIHB2xB", 4, 0, 0x01000800, 7, 0, 0))
    body += subrecord(b"COED", struct.pack("<IIf", 0, 0, 0.5))
    return plugin(["Fallout4.esm"], target + record(b"LVLI", body, form_id=0x01000801), 2, True)


def idle_record(name, index, model, parent=0, previous=0):
    body = subrecord(b"EDID", name.encode("ascii") + b"\0")
    body += subrecord(b"MODL", model.encode("ascii") + b"\0")
    body += subrecord(b"ANAM", struct.pack("<II", parent, previous))
    body += subrecord(b"DATA", struct.pack("<BBBBhBB", 0, 1, 1, 0, 2, 0, 0))
    return struct.pack("<4sIIIIHH", b"IDLE", len(body), 0, 0x01000000 + index, 0, 15, 0) + body


def idle_plugin(masters, records, count, esm=False):
    header = subrecord(b"HEDR", struct.pack("<fII", 0.94, count, 0x900))
    for master in masters:
        header += subrecord(b"MAST", master.encode("ascii") + b"\0")
        header += subrecord(b"DATA", b"\0" * 8)
    group = struct.pack("<4sI4sIHHHH", b"GRUP", len(records) + 24, b"IDLE", 0, 0, 0, 0, 0) + records
    return struct.pack("<4sIIIIHH", b"TES4", len(header), int(esm), 0, 0, 15, 0) + header + group


def fixtures(game):
    if game == "fo4":
        return {SOURCE: leveled_source(),
                WRAPPER: plugin(["Fallout4.esm"], b"", 0),
                SPAWN: plugin(["Fallout4.esm"], b"", 0)}
    base = idle_record("AutoIdleA", 0x800, r"characters\old\a.kf", 0x01000801)
    base += idle_record("AutoIdleB", 0x801, r"characters\old\b.kf", 0x01000802, 0x01000800)
    base += idle_record("AutoIdleC", 0x802, r"characters\old\c.kf", 0x01000803, 0x01000801)
    base += idle_record("AutoIdleExternal", 0x803, r"characters\outside\external.kf")
    winner = idle_record("AutoIdleB", 0x801, r"characters\old\b_winner.kf", 0x01000802, 0x01000800)
    return {IDLES: idle_plugin(["Fallout3.esm"], base, 4, True),
            WINNER: idle_plugin(["Fallout3.esm", IDLES], winner, 1),
            COPIES: idle_plugin(["Fallout3.esm"], b"", 0)}


def discover(client, file, signature):
    result = client.call("records.list", file=file, signature=signature, limit=100)
    assert not result["truncated"], result
    return {item["object"]["editorId"]: item["locator"] for item in result["records"]}


def children(client, locator):
    result = client.call("elements.children", **locator, limit=100)
    assert not result["truncated"], result
    return result["children"]


def value(client, locator, path=None):
    return client.call("elements.get_value", **{**locator, **({"path": path} if path else {})})["values"]["editValue"]


def entry_state(client, locator):
    entries = children(client, {**locator, "path": "Leveled List Entries"})
    states = []
    for entry in entries:
        members = children(client, entry["locator"])
        payload = next((member for member in members if member["object"]["name"].startswith("LVLO")), None)
        fields = children(client, payload["locator"]) if payload else members
        state = {member["object"]["name"]: value(client, member["locator"])
                 for member in fields if member["object"]["name"] in ("Count", "Level")}
        ownership = next((member for member in members if member["object"]["name"].startswith("COED")), None)
        state["ownership"] = ({member["object"]["name"]: value(client, member["locator"])
                               for member in children(client, ownership["locator"])} if ownership else None)
        states.append(state)
    return states


def references(client, locator):
    return {item["locator"]["formId"] for item in
            client.call("records.references", **locator, limit=100)["hits"]}


def verify_leveled(client):
    source = discover(client, SOURCE, "LVLI")["AutoCopySource"]
    wrapper = discover(client, WRAPPER, "LVLI")
    spawn = discover(client, SPAWN, "LVLI")["AutoCopySource"]
    original = entry_state(client, source)
    assert len(original) == 1 and int(original[0]["Count"]) == 7, original
    forwarding = entry_state(client, wrapper["AutoCopySource"])
    assert len(forwarding) == 1 and forwarding[0]["Count"] == forwarding[0]["Level"] == "1", forwarding
    assert wrapper["AutoWrappedContent"]["formId"] in references(client, wrapper["AutoCopySource"])
    assert entry_state(client, wrapper["AutoWrappedContent"]) == original
    spawned = entry_state(client, spawn)
    assert len(spawned) == 10, spawned
    assert Counter(int(item["Count"]) for item in spawned) == Counter([7, 1, 1, 2, 2, 2, 2, 2, 3, 3]), spawned
    assert all(item["Level"] == original[0]["Level"] and
               item["ownership"] == original[0]["ownership"] for item in spawned), spawned
    assert references(client, spawn) == references(client, source)


def exercise_leveled(client):
    source = discover(client, SOURCE, "LVLI")["AutoCopySource"]
    before = client.call("session.get_dirty_state")["mutationRevision"]
    for mode, target in (("wrapper", WRAPPER), ("spawn_rate", SPAWN)):
        args = {"source": source, "target": {"file": target}, "mode": mode}
        if mode == "wrapper":
            args["editorId"] = "AutoWrappedContent"
        planned = client.call("records.copy_into", **args)
        assert planned["dryRun"] and not planned["changed"], planned
        assert not discover(client, target, "LVLI")
    assert client.call("session.get_dirty_state")["mutationRevision"] == before
    for mode, target in (("wrapper", WRAPPER), ("spawn_rate", SPAWN)):
        args = {"source": source, "target": {"file": target}, "mode": mode, "dryRun": False}
        if mode == "wrapper":
            args["editorId"] = "AutoWrappedContent"
        applied = client.call("records.copy_into", **args)
        assert applied["changed"], applied
        if mode == "wrapper":
            assert applied["wrappedLocator"]["formId"] != applied["locator"]["formId"], applied
        revision = client.call("session.get_dirty_state")["mutationRevision"]
        denied = client.request(json.dumps({"command": "records.copy_into", "args": args}))
        assert not denied["ok"], denied
        assert client.call("session.get_dirty_state")["mutationRevision"] == revision
    verify_leveled(client)
    client.call("session.save", files=[WRAPPER, SPAWN])
    client.call("session.flush")


def verify_idles(client):
    source = discover(client, IDLES, "IDLE")
    copies = discover(client, COPIES, "IDLE")
    assert set(copies) == {"CopiedAutoIdleA", "CopiedAutoIdleB", "CopiedAutoIdleC"}, copies
    paths = {"A": "a.kf", "B": "b_winner.kf", "C": "c.kf"}
    for name, suffix in paths.items():
        assert value(client, copies["CopiedAutoIdle" + name], r"MODL\MODL").lower() == "characters\\new\\" + suffix
    assert copies["CopiedAutoIdleB"]["formId"] in references(client, copies["CopiedAutoIdleA"])
    assert copies["CopiedAutoIdleC"]["formId"] in references(client, copies["CopiedAutoIdleB"])
    assert copies["CopiedAutoIdleA"]["formId"] in references(client, copies["CopiedAutoIdleB"])
    assert source["AutoIdleExternal"]["formId"] in references(client, copies["CopiedAutoIdleC"])
    assert value(client, source["AutoIdleA"], r"MODL\MODL").lower() == r"characters\old\a.kf"


def exercise_idles(client):
    source = discover(client, IDLES, "IDLE")
    sources = [source["AutoIdle" + name] for name in "ABC"]
    args = {"sources": sources, "targetFile": COPIES, "oldModelPrefix": r"characters\old",
            "newModelPrefix": r"characters\new", "editorIdPrefix": "Copied"}
    before = client.call("session.get_dirty_state")["mutationRevision"]
    plan = client.call("records.copy_idle_tree", **args)
    assert plan["complete"] and not plan["changed"], plan
    assert plan["mappings"][1]["source"]["file"] == WINNER, plan
    assert not discover(client, COPIES, "IDLE")
    denied = client.request(json.dumps({"command": "records.copy_idle_tree", "args": {
        **args, "sources": [sources[0], sources[0]], "dryRun": False}}))
    assert not denied["ok"], denied
    assert client.call("session.get_dirty_state")["mutationRevision"] == before
    applied = client.call("records.copy_idle_tree", **args, dryRun=False)
    assert applied["complete"] and applied["copied"] == applied["rewritten"] == 3, applied
    verify_idles(client)
    client.call("session.save", files=[COPIES])
    client.call("session.flush")


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("game", choices=("fo4", "fo3"))
    parser.add_argument("phase", choices=("generate", "exercise", "verify"))
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        args.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures(args.game).items():
            with (args.overlay / name).open("xb") as stream:
                stream.write(data)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Live phases require --exe, --pid and --artifacts")
        client = Client(args.exe, args.pid, args.artifacts)
        action = ({"exercise": exercise_leveled, "verify": verify_leveled} if args.game == "fo4"
                  else {"exercise": exercise_idles, "verify": verify_idles})
        action[args.phase](client)


if __name__ == "__main__":
    main()
