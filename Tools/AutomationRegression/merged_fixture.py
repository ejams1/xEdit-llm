"""FO3 sibling-baseline native merge scene; live exercise and fresh readback."""
import argparse
from pathlib import Path
import struct
from itm_fixture import Client, subrecord
from copy_modes_fixture import discover, children, value, references, entry_state

BASE = "AutomationMergeBase.esm"
LEFT = "AutomationMergeLeft.esp"
RIGHT = "AutomationMergeRight.esp"
OUTPUT = "AutomationMergeOutput.esp"
A, B, C, D = (0x01000900 + n for n in range(1, 5))
NAMES = ("MergeMultiset", "MergeSet", "MergeOrderedList", "MergeFaultyOrderedList")


def record(signature, data, identity=0, flags=0):
    return struct.pack("<4sIIIIHH", signature, len(data), flags, identity, 0, 15, 0) + data


def leveled(name, identity, targets, chance=0):
    data = subrecord(b"EDID", name.encode("ascii") + b"\0") + subrecord(b"OBND", b"\0" * 12)
    data += subrecord(b"LVLD", bytes([chance])) + subrecord(b"LVLF", b"\0")
    for target in targets:
        data += subrecord(b"LVLO", struct.pack("<HHIHBB", 1, 0, target, 2, 0, 0))
        data += subrecord(b"COED", struct.pack("<IIf", 0, 0, 0.5))
    return record(b"LVLI", data, identity)


def form_list(name, identity, targets):
    data = subrecord(b"EDID", name.encode("ascii") + b"\0")
    return record(b"FLST", data + b"".join(subrecord(b"LNAM", struct.pack("<I", x)) for x in targets), identity)


def plugin(masters, groups, count, esm=False):
    header = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0xA00))
    for master in masters:
        header += subrecord(b"MAST", master.encode("ascii") + b"\0") + subrecord(b"DATA", b"\0" * 8)
    data = record(b"TES4", header, flags=int(esm))
    for signature, body in groups:
        data += struct.pack("<4sI4sIHHHH", b"GRUP", len(body) + 24, signature, 0, 0, 0, 0, 0) + body
    return data


def fixtures():
    result = {}
    for file, multi, plain, ordered, faulty, chance in (
        (BASE, [A, A, B], [A, B], [A], [A, B], 0),
        (LEFT, [A, C], [A, C], [A, C], [B, A, C], 0),
        (RIGHT, [A, A, B, D], [A, B, D], [A, D], [A, B, D], 23),
    ):
        lists = leveled(NAMES[0], 0x01000800, multi, chance)
        if file == BASE:
            for name, identity in zip("ABCD", (A, B, C, D)):
                lists += leveled("MergeTarget" + name, identity, [])
        forms = b"".join(form_list(name, 0x01000800 + index, targets)
                         for index, (name, targets) in enumerate(zip(NAMES[1:], (plain, ordered, faulty)), 1))
        masters = ["Fallout3.esm"] + ([] if file == BASE else [BASE])
        result[file] = plugin(masters, [(b"LVLI", lists), (b"FLST", forms)], 8 if file == BASE else 4, file == BASE)
    result[OUTPUT] = plugin(["Fallout3.esm"], [], 0)
    return result


def selections(client):
    base = {**discover(client, BASE, "LVLI"), **discover(client, BASE, "FLST")}
    return [base[name] for name in NAMES]


def form_ids(client, locator):
    return [int(client.call("elements.get_value", **row["locator"])["values"]["nativeValue"]["value"]) & 0xFFFFFFFF
            for row in children(client, {**locator, "path": "FormIDs"})]


def verify(client):
    lists = discover(client, OUTPUT, "LVLI")
    forms = discover(client, OUTPUT, "FLST")
    assert set(lists) == {NAMES[0]} and set(forms) == set(NAMES[1:3]), (lists, forms)
    merged = lists[NAMES[0]]
    assert references(client, merged) == {f"{x:08X}" for x in (A, C, D)}
    states = entry_state(client, merged)
    assert len(states) == 3 and all(x["Level"] == "1" and x["Count"] == "2" for x in states), states
    assert all(x["ownership"] == states[0]["ownership"] for x in states), states
    chance = next(x for x in children(client, merged) if x["object"]["name"].startswith("LVLD"))
    assert value(client, chance["locator"]) == "23"
    assert set(form_ids(client, forms[NAMES[1]])) == {A, C, D}
    assert form_ids(client, forms[NAMES[2]]) == [A, C, D]
    assert set(discover(client, BASE, "LVLI")) == {NAMES[0], *("MergeTarget" + x for x in "ABCD")}


def exercise(client):
    args = dict(records=selections(client), targetFile=OUTPUT)
    before = client.call("session.get_dirty_state")
    plan = client.call("patches.merge", **args)
    assert plan["complete"] and plan["dryRun"] and not plan["changed"], plan
    assert [x["outcome"] for x in plan["records"]] == ["planned"] * 3 + ["faulty-ordered-list"], plan
    after = client.call("session.get_dirty_state")
    assert before["mutationRevision"] == after["mutationRevision"] and before["dirtyFiles"] == after["dirtyFiles"]
    assert not discover(client, OUTPUT, "LVLI") and not discover(client, OUTPUT, "FLST")
    applied = client.call("patches.merge", **args, dryRun=False)
    assert applied["complete"] and applied["changed"] and applied["requiresSave"], applied
    assert [x["outcome"] for x in applied["records"]] == ["applied"] * 3 + ["faulty-ordered-list"], applied
    verify(client)
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
        (exercise if args.phase == "exercise" else verify)(Client(args.exe, args.pid, args.artifacts))


if __name__ == "__main__":
    main()
