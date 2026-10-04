"""FO4 logical subtree/projection/batch read acceptance; no plugin writes.

Generate into a fresh MO2 overlay and enable the two generated plugins. Python
tests check fixture bytes/assertions only; licensed Delphi/native execution is
required to verify the Pascal traversal.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord
from pagination_fixture import drain
from row_fixture import form_list, keyword, misc, message
from selective_step_fixture import group

BASE = "AutomationSubtreeBase.esm"
SCENE = "AutomationSubtreeScene.esp"
KEYWORDS = 96
DENSE_REFS = 80
DENSE_ARRAY = 600


def header(masters, count, esm=False):
    body = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0x5000))
    for master in masters:
        body += subrecord(b"MAST", master.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    return record(b"TES4", body, int(esm))


def fixtures():
    base = group(b"KYWD", 0, b"".join(keyword(f"SubtreeKeyword{i:03d}", 0x01000800 + i)
                                    for i in range(KEYWORDS)))
    static = subrecord(b"EDID", b"SubtreeStatic\0") + subrecord(b"OBND", b"\0" * 12)
    static += subrecord(b"MODL", b"automation\\subtree.nif\0")
    base += group(b"STAT", 0, record(b"STAT", static, form_id=0x01001000))
    objects = group(b"MISC", 0, misc("SubtreeSmall", 0x02001100, range(0x01000800, 0x01000820)) +
                    misc("SubtreeEmpty", 0x02001101, []))
    array = [0x01000800 + i % KEYWORDS for i in range(DENSE_ARRAY)]
    objects += group(b"FLST", 0, form_list("SubtreeDenseArray", 0x02001200, array))
    long_text = "界" * 500 + " exact text "
    buttons = b"".join(subrecord(b"ITXT", (f"{i:02d}: " + long_text).encode("utf-8") + b"\0")
                       for i in range(50))
    msg = message("SubtreeUnicode", 0x02001300, long_text, "Subtree title", flags=1)
    # Extend the payload and update its record size; no new TES4 record is added.
    msg = record(b"MESG", msg[24:] + buttons, form_id=0x02001300)
    objects += group(b"MESG", 0, msg)
    cells = []
    for identity, first, count, name in ((0x02003000, 0x02002000, 4, "SubtreeSmallCell"),
                                        (0x02004000, 0x02002100, DENSE_REFS, "SubtreeDenseCell")):
        cell = record(b"CELL", subrecord(b"EDID", name.encode() + b"\0") +
                      subrecord(b"DATA", b"\1\0"), form_id=identity)
        refs = []
        for index in range(count):
            body = subrecord(b"EDID", f"{name}Ref{index:03d}".encode() + b"\0")
            body += subrecord(b"NAME", struct.pack("<I", 0x01001000))
            body += subrecord(b"DATA", struct.pack("<6f", 100, 200, 300, 0, 0, 0))
            refs.append(record(b"REFR", body, form_id=first + index))
        children = group(identity, 6, group(identity, 9, b"".join(refs)))
        object_id = identity & 0xFFFFFF
        cells.append(group(object_id % 10, 2, group(object_id // 10 % 10, 3, cell + children)))
    objects += group(b"CELL", 0, b"".join(cells))
    return {BASE: header(["Fallout4.esm"], KEYWORDS + 1, True) + base,
            SCENE: header(["Fallout4.esm", BASE], 90) + objects}


def compact_bytes(value):
    return len(json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def identity(locator):
    return locator["file"].casefold(), locator["formId"].upper(), locator["path"]


def validate_subtree(value):
    nodes, limits = value["nodes"], value["limits"]
    assert value["count"] == len(nodes) <= limits["maxNodes"] <= 256, value
    assert 0 <= limits["maxDepth"] <= 8, value
    assert len({identity(node["locator"]) for node in nodes}) == len(nodes), value
    assert len(set(value["truncationReasons"])) == len(value["truncationReasons"]), value
    assert set(value["truncationReasons"]) <= {"maxNodes", "maxDepth", "visitLimit", "responseBytes"}, value
    assert value["complete"] == (not value["truncated"]) == (not value["truncationReasons"]), value
    assert 0 <= value["visitedUnits"] <= limits["visitLimit"] == 1024, value
    assert compact_bytes(value) <= limits["responseBytes"] == 1048576, value
    assert not value["nativeCallsPreemptible"] and value["order"] == "preorder", value
    stack = []
    for index, node in enumerate(nodes):
        depth, parent = node["depth"], node["parentIndex"]
        assert 0 <= depth <= limits["maxDepth"] and node["childSlots"] >= 0, node
        if index == 0:
            assert depth == 0 and parent == -1 and node["locator"] == value["root"], node
        else:
            assert 0 <= parent < index and depth == nodes[parent]["depth"] + 1, node
        while len(stack) > depth:
            stack.pop()
        assert len(stack) == depth, node
        if stack:
            assert parent == stack[-1], node
            if node["complete"] is False:
                assert all(not nodes[ancestor]["complete"] for ancestor in stack), value
        stack.append(index)
        if value["complete"]:
            assert node["complete"], node
        if node["object"]["kind"] == "child_group" and "signatureScanCount" in node["object"]:
            hints = node["object"]
            assert 0 <= hints["signatureScanCount"] <= hints["signatureScanLimit"] <= 32, hints
            assert hints["signaturesComplete"] == (hints["signatureScanCount"] == hints["count"]), hints
    if nodes:
        assert nodes[0]["complete"] == value["complete"], value
    else:
        assert not value["complete"], value


def immediate_children(client, locator):
    """Independently drain old child pages, ordering the virtual group last."""
    regular, virtual, offset = [], [], 0
    for _ in range(10000):
        page = client.call("elements.children", **locator, limit=37, offset=offset, fields=[])
        for child in page["children"]:
            is_virtual = (locator["path"] == "" and child["object"]["kind"] == "child_group" and
                          child["locator"]["path"] == r"\Child Group")
            (virtual if is_virtual else regular).append(child)
        if not page["truncated"]:
            return regular + virtual
        offset += 37  # Offset counts native slots, not emitted/suppressed rows.
    raise AssertionError("Child page drain did not finish")


def reference_tree(client, locator):
    nodes = []

    def walk(current, depth, parent, may_have_children=True):
        assert depth < 64, "Malformed native hierarchy"
        index = len(nodes)
        nodes.append({"locator": current, "depth": depth, "parentIndex": parent})
        if may_have_children:
            for child in immediate_children(client, current):
                walk(child["locator"], depth + 1, index, "children" in child.get("relations", {}))
    walk(locator, 0, -1)
    return nodes


def topology(nodes):
    return [(identity(n["locator"]), n["depth"], n["parentIndex"]) for n in nodes]


def reject(client, locator, expected="invalid_request", **args):
    result = client.request(json.dumps({"command": "elements.subtree", "args": {**locator, **args}}))
    assert not result["ok"] and result["error"]["code"] == expected, result


def exercise(client, overlay, artifacts):
    baseline = client.call("session.get_dirty_state")
    assert not baseline["dirty"] and not baseline["pendingShutdownCount"], baseline
    scene, _ = drain(client, "records.list", "records", {"file": SCENE, "limit": 100})
    by_name = {row["object"]["editorId"]: row["locator"] for row in scene if "editorId" in row["object"]}
    report = {"nativeBuildAndRuntimeRequired": True, "cases": [], "hardLatencyGuaranteeTested": False}

    def read(locator, **args):
        started = time.monotonic()
        result = client.call("elements.subtree", **locator, **args)
        validate_subtree(result)
        report["cases"].append({"root": locator, "args": args, "secondsIncludingIPC": time.monotonic() - started,
                                "bytes": compact_bytes(result), "result": result})
        return result

    for name in ("SubtreeSmall", "SubtreeEmpty", "SubtreeSmallCell", "SubtreeUnicode"):
        locator = by_name[name]
        sequence = client.sequence
        expected = reference_tree(client, locator)
        calls = client.sequence - sequence
        full = read(locator, maxNodes=256, maxDepth=8)
        assert full["complete"] and topology(full["nodes"]) == topology(expected), (name, full, expected)
        projected = read(locator, maxNodes=256, maxDepth=8, fields=[], includeRelations=False)
        assert topology(projected["nodes"]) == topology(expected)
        assert all(set(node["object"]) <= {"kind", "formId", "path"} and "relations" not in node
                   for node in projected["nodes"]), projected
        assert compact_bytes(projected) < compact_bytes(full)
        assert calls > 1, (name, calls)
        report.setdefault("roundTrips", {})[name] = {"explicitChildren": calls, "subtree": 1}
        # Depth cuts branches but still includes every immediate root child.
        shallow = read(locator, maxNodes=256, maxDepth=1, fields=[])
        expected_shallow = [node for node in expected if node["depth"] <= 1]
        assert [identity(n["locator"]) for n in shallow["nodes"]] == [identity(n["locator"]) for n in expected_shallow]
        root_only = read(locator, maxNodes=1, maxDepth=0)
        assert root_only["count"] == 1 and not root_only["complete"] and "maxDepth" in root_only["truncationReasons"]
        for node in full["nodes"]:
            resolved = client.call("elements.children", **node["locator"], limit=1, fields=[])
            assert resolved["total"] >= 0, node

    small = by_name["SubtreeSmall"]
    leaf = {**small, "path": "EDID"}
    result = read(leaf, maxNodes=1, maxDepth=0)
    assert result["complete"] and result["count"] == 1 and result["nodes"][0]["childSlots"] == 0, result
    dense = {**by_name["SubtreeDenseArray"], "path": "FormIDs"}
    expected = reference_tree(client, dense)
    assert len(expected) == DENSE_ARRAY + 1, expected
    for count in (1, 3, 50, 256):
        prefix = read(dense, maxNodes=count, maxDepth=8, fields=[], includeRelations=False)
        assert not prefix["complete"] and "maxNodes" in prefix["truncationReasons"], prefix
        assert topology(prefix["nodes"]) == topology(expected[:count]), prefix

    # Small child pages must not silently scan all 80 referrers for hint signatures.
    dense_cell = by_name["SubtreeDenseCell"]
    group_locator = {**dense_cell, "path": r"\Child Group"}
    page = client.call("elements.children", **group_locator, limit=1)
    temporary = next(child for child in page["children"] if child["object"]["kind"] == "child_group")
    hints = temporary["object"]
    assert hints["count"] == DENSE_REFS and hints["signatureScanCount"] == hints["signatureScanLimit"] == 32
    assert not hints["signaturesComplete"], hints
    group_prefix = read(temporary["locator"], maxNodes=2, maxDepth=8)
    assert not group_prefix["complete"] and group_prefix["nodes"][0]["object"]["count"] == DENSE_REFS
    parents = read(by_name["SubtreeSmallCell"], maxNodes=256, maxDepth=8, includeParents=True)
    ref_nodes = [node for node in parents["nodes"] if node["object"].get("signature") == "REFR"]
    assert ref_nodes and all(node.get("relations", {}).get("parents") for node in ref_nodes), parents
    alias = {**by_name["SubtreeSmallCell"], "path": r"\Child Group\Temporary\[0]"}
    aliased = read(alias, maxNodes=256, maxDepth=8)
    assert aliased["root"]["path"] == "" and aliased["root"]["formId"] == ref_nodes[0]["locator"]["formId"], aliased
    field_alias = {**alias, "path": alias["path"] + r"\EDID"}
    aliased_field = read(field_alias, maxNodes=1, maxDepth=0)
    assert aliased_field["complete"] and aliased_field["root"]["formId"] == aliased["root"]["formId"], aliased_field
    assert client.call("elements.get_value", **aliased_field["root"])["values"]["editValue"] == "SubtreeSmallCellRef000"

    for args in ({"maxNodes": 0}, {"maxNodes": 257}, {"maxNodes": 2**64 - 1},
                 {"maxNodes": True}, {"maxDepth": -1}, {"maxDepth": 9}, {"maxDepth": 1.5},
                 {"fields": ["unknown"]}, {"includeRelations": "false"}):
        reject(client, small, **args)
    reject(client, small, expected="stale_revision", expectedRevision=str(int(baseline["mutationRevision"]) + 1))
    read(small, expectedRevision=baseline["mutationRevision"])

    base, _ = drain(client, "records.list", "records", {"file": BASE, "signature": "KYWD", "limit": 100})
    batch = client.call("batch.read", items=[
        {"command": "records.get", "args": base[0]["locator"]},
        {"command": "elements.subtree", "args": {**leaf, "maxNodes": 1, "maxDepth": 0}},
        {"command": "elements.subtree", "args": {**dense, "maxNodes": 3, "fields": []}},
        {"command": "elements.get_value", "args": leaf}])
    assert not batch["complete"] and len(batch["items"]) == 4 and batch["total"] == 4, batch
    for row in batch["items"][1:3]:
        validate_subtree(row["result"])
    assert batch["items"][3]["result"]["values"]["editValue"] == "SubtreeSmall", batch
    for args in ({**small}, {**small, "maxNodes": 51}):
        denied = client.request(json.dumps({"command": "batch.read", "args": {
            "items": [{"command": "elements.subtree", "args": args}]}}))
        assert not denied["ok"] and denied["error"]["code"] == "invalid_request", denied

    # Read probes remain usable while a job owns the graph; this does not advance it.
    job = client.call("jobs.start", kind="validation.check_for_itm", target={"files": [SCENE]})
    read(small)
    canceled = client.call("jobs.cancel", jobId=job["jobId"])
    assert canceled["state"] == "canceled" and canceled["progress"]["completed"] == 0, canceled
    client.call("jobs.discard", jobId=job["jobId"])
    assert client.call("session.get_dirty_state") == baseline
    for name, blob in fixtures().items():
        assert (overlay / name).read_bytes() == blob, name
    (artifacts / "subtree-read.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")


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
            with (args.overlay / name).open("xb") as stream:
                stream.write(blob)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Live exercise requires --exe, --pid and --artifacts")
        exercise(Client(args.exe, args.pid, args.artifacts), args.overlay, args.artifacts)


if __name__ == "__main__":
    main()
