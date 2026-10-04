"""FO4 recursive reference selection/sort paging and cursor invalidation.

Generate into a fresh MO2 overlay; enable BASE, PATCH, OUTSIDE in that order
after Fallout4.esm. Exercise requires a fresh consent-enabled native daemon.
Python tests validate fixture bytes and acceptance assertions, not Pascal.
"""
import argparse
import json
from pathlib import Path
import struct
import time

from itm_fixture import Client, record, subrecord
from pagination_fixture import drain
from reference_fixture import rebuild
from row_fixture import disk_state, keyword, misc
from selective_step_fixture import group

BASE = "AutomationRelationshipBase.esm"
PATCH = "AutomationRelationshipPatch.esp"
OUTSIDE = "AutomationRelationshipOutside.esp"
COUNT = 700
PREFIX = "RelationshipAcousticSpace"
SHARED = "RelationshipSharedDoor"
LATER = "RelationshipLaterOnlyRef"


def target(index):
    return f"RelationshipTarget{index:04d}"


def plugin(masters, groups, count, esm=False):
    body = subrecord(b"HEDR", struct.pack("<fII", 1.0, count, 0x7000))
    for master in masters:
        body += subrecord(b"MAST", master.encode() + b"\0") + subrecord(b"DATA", b"\0" * 8)
    return record(b"TES4", body, int(esm)) + b"".join(groups)


def placed(index, destination, identity=None, name=None, shared=True):
    body = subrecord(b"EDID", (name or f"RelationshipRef{index:04d}").encode() + b"\0")
    body += subrecord(b"NAME", struct.pack("<I", destination))
    if shared:
        # FO4 XTEL: door FormID, position/rotation, flags, transition CELL.
        body += subrecord(b"XTEL", struct.pack("<I6fII", 0x01006000, 0, 0, 0, 0, 0, 0, 0, 0))
    body += subrecord(b"DATA", struct.pack("<6f", 100, 200, 300, 0, 0, 0))
    return record(b"REFR", body, 0x400 if index % 2 else 0,
                  0x01004000 + index if identity is None else identity)


def cell(identity, name, refs=(), prefix=False):
    body = subrecord(b"EDID", name.encode() + b"\0") + subrecord(b"DATA", b"\1\0")
    if prefix:
        body += subrecord(b"XCAS", struct.pack("<I", 0x01001000))
    rows = record(b"CELL", body, form_id=identity)
    persistent = b"".join(blob for index, blob in refs if index % 2)
    temporary = b"".join(blob for index, blob in refs if not index % 2)
    children = (group(identity, 8, persistent) if persistent else b"")
    children += group(identity, 9, temporary) if temporary else b""
    if children:
        rows += group(identity, 6, children)
    object_id = identity & 0xFFFFFF
    return group(object_id % 10, 2, group(object_id // 10 % 10, 3, rows))


def fixtures():
    objects = b"".join(misc(target(i), 0x01000800 + i,
                            [0x01001200] if i == 1 else []) for i in range(COUNT * 2))
    objects += misc("RelationshipOutsideTarget", 0x01001100, [])
    acoustic = subrecord(b"EDID", PREFIX.encode() + b"\0") + subrecord(b"OBND", b"\0" * 12)
    acoustic += subrecord(b"XTRI", b"\1") + subrecord(b"WNAM", b"\0\0")
    base_cells = cell(0x01003000, "RelationshipRoot",
                      [(i, placed(i, 0x01000800 + i)) for i in range(COUNT)], True)
    base_cells += cell(0x01003100, "RelationshipOtherRoot", [
        (0, placed(0, 0x01001100, 0x01006000, SHARED, shared=False))])
    base_cells += cell(0x01003200, "RelationshipNoOwnChildren", prefix=True)
    base_cells += cell(0x01003300, "RelationshipEmpty")
    patches = [(i, placed(i, 0x01000800 + COUNT + i)) for i in range(COUNT) if i % 3 == 0]
    patch_cells = cell(0x01003000, "RelationshipRoot", patches, True)
    patch_cells += cell(0x01003200, "RelationshipNoOwnChildren", [
        (0, placed(0, 0x01000800 + COUNT + 100, 0x02005000, LATER, shared=False))], True)
    # The global winner of child 5 is outside the main root's selected parent
    # child groups. Native sibling selection must keep the base version there.
    outside_cells = cell(0x01003100, "RelationshipOtherRoot", [(5, placed(5, 0x01001100))])
    return {
        BASE: plugin(["Fallout4.esm"], [group(b"MISC", 0, objects),
            group(b"ASPC", 0, record(b"ASPC", acoustic, form_id=0x01001000)),
            group(b"KYWD", 0, keyword("RelationshipNeverFollowedKeyword", 0x01001200)),
            group(b"CELL", 0, base_cells)], COUNT * 3 + 8, True),
        PATCH: plugin(["Fallout4.esm", BASE], [group(b"CELL", 0, patch_cells)], len(patches) + 3),
        OUTSIDE: plugin(["Fallout4.esm", BASE], [group(b"CELL", 0, outside_cells)], 2),
    }


def expected_names(patch_only=False):
    indices = [i for i in range(COUNT) if not patch_only or i % 3 == 0]
    names = [PREFIX]
    for i in indices:
        names.append(target(COUNT + i if i % 3 == 0 else i))
        if i == 0:
            names.append(SHARED)
    return names


def identity(row):
    locator = row["locator"]
    return locator["file"].casefold(), locator["formId"].upper()


def validate_page(page, previous=None):
    progress = page["traversal"]
    assert page["count"] == len(page["hits"]) <= page["limit"] <= 500, page
    assert 0 <= page["scanned"] <= progress["pageWorkLimit"] == 5000, page
    assert progress["softPageBudgetMs"] == 100 and not progress["nativeCallsPreemptible"], page
    assert 0 <= progress["selectedChildRoots"] <= progress["rootLimit"] == 100000, page
    assert 0 <= progress["selectionWork"] <= progress["selectionWorkLimit"] == 1000000, page
    assert 0 <= progress["payloadWork"] <= progress["payloadWorkLimit"] == 100000, page
    assert 0 <= progress["retainedChildRoots"] <= progress["selectedChildRoots"], page
    assert 0 <= progress["retainedDepth"] <= 128 and 0 < progress["accountedRetainedBytes"] <= 67108864, page
    assert progress["sortWork"] >= 0 and progress["candidateVersions"] >= progress["selectedChildRoots"], page
    assert page["revision"].isdigit() and page["semanticRevision"].isdigit(), page
    phases = ["root-payload", "select-child-roots", "sort-child-roots", "child-payload", "complete"]
    assert progress["phase"] in phases, page
    assert page["cursorRetained"] == bool(page.get("nextCursor")) == page["truncated"], page
    assert not page["incomplete"], page
    assert page["complete"] == (not page["cursorRetained"]), page
    if page["complete"]:
        assert progress["phase"] == "complete" and progress["rootSelectionComplete"], page
        assert progress["retainedDepth"] == progress["retainedChildRoots"] == 0, page
    if previous:
        assert (page["revision"], page["semanticRevision"]) == (previous["revision"], previous["semanticRevision"]), page
        before = previous["traversal"]
        assert phases.index(progress["phase"]) >= phases.index(before["phase"]), page
        for key in ("scannedTotal", "emittedTotal"):
            assert page[key] >= previous[key], page
        for key in ("selectedChildRoots", "candidateVersions", "selectionWork", "sortWork", "payloadWork"):
            assert progress[key] >= before[key], page


def reject(client, command, args, code):
    value = client.request(json.dumps({"command": command, "args": args}))
    assert not value["ok"] and value["error"]["code"] == code, value


def exercise(client, overlay, artifacts):
    baseline = client.call("session.get_dirty_state")
    assert not baseline["dirty"] and not baseline["pendingShutdownCount"], baseline
    originals = fixtures()
    for name, blob in originals.items():
        assert (overlay / name).read_bytes() == blob, name
    by_file = {}
    for name in originals:
        rows, _ = drain(client, "records.list", "records", {"file": name, "limit": 500})
        by_file[name] = {row["object"]["editorId"]: row["locator"] for row in rows if "editorId" in row["object"]}
    report = {"nativeBuildAndRuntimeRequired": True, "hardLatencyGuaranteeTested": False, "cases": []}

    def read(locator, **options):
        query = {**locator, "recursive": True, "limit": 37, **options}
        hits, pages, cursor = [], [], None
        for _ in range(10000):
            started = time.monotonic()
            page = client.call("records.references", **query, **({"cursor": cursor} if cursor else {}))
            validate_page(page, pages[-1] if pages else None)
            pages.append(page)
            hits.extend(page["hits"])
            report["cases"].append({"query": query, "secondsIncludingIPC": time.monotonic() - started, "page": page})
            cursor = page.get("nextCursor")
            if not cursor:
                assert len(set(map(identity, hits))) == len(hits), hits
                return hits, pages
        raise AssertionError("Reference drain failed to finish")

    root = by_file[BASE]["RelationshipRoot"]
    small, pages = read(root, limit=1)
    assert [row["object"]["editorId"] for row in small] == expected_names(), small
    assert any(page["traversal"]["phase"] == "sort-child-roots" and page.get("nextCursor") for page in pages), pages
    final = pages[-1]["traversal"]
    assert final["selectedChildRoots"] == COUNT and final["candidateVersions"] == COUNT + len(range(0, COUNT, 3)), final
    for limit in (37, 500):
        hits, _ = read(root, limit=limit)
        assert list(map(identity, hits)) == list(map(identity, small)), hits
    offset, _ = read(root, limit=37, offset=19)
    assert list(map(identity, offset)) == list(map(identity, small[19:])), offset
    projected, _ = read(root, fields=[], includeRelations=False)
    assert list(map(identity, projected)) == list(map(identity, small)), projected
    assert all(set(row["object"]) <= {"kind", "formId", "path"} and "relations" not in row for row in projected), projected
    shallow, _ = read(root, recursive=False)
    assert [row["object"]["editorId"] for row in shallow] == [PREFIX], shallow
    scoped, _ = read(by_file[PATCH]["RelationshipRoot"])
    assert [row["object"]["editorId"] for row in scoped] == expected_names(patch_only=True), scoped
    later, _ = read(by_file[BASE]["RelationshipNoOwnChildren"])
    assert [row["object"]["editorId"] for row in later] == [PREFIX, target(COUNT + 100)], later
    empty, _ = read(by_file[BASE]["RelationshipEmpty"])
    assert empty == [], empty

    # Argument refusal must preserve the original token; a consumed token may
    # not skip a page on retry. The first limit=1 page has many hits remaining.
    query = {**root, "recursive": True, "limit": 1}
    first = client.call("records.references", **query)
    token = first["nextCursor"]
    reject(client, "records.references", {**query, "cursor": token, "limit": 2}, "invalid_request")
    resumed = client.call("records.references", **query, cursor=token)
    validate_page(resumed, first)
    reject(client, "records.references", {**query, "cursor": token}, "cursor_invalidated")
    # Native reference-index work invalidates semantic generations even when
    # the plugins' mutation generation does not change.
    current = client.call("records.references", **query)
    before_index = client.call("session.get_dirty_state")
    report["referenceIndexJob"] = rebuild(client, allLoaded=True)
    assert client.call("session.get_dirty_state")["mutationRevision"] == before_index["mutationRevision"]
    reject(client, "records.references", {**query, "cursor": current["nextCursor"]}, "cursor_invalidated")
    reverse_query = {**by_file[BASE][target(COUNT)], "limit": 1}
    reverse, reverse_pages = drain(client, "records.referenced_by", "hits", reverse_query)
    assert [identity(row) for row in reverse] == [(PATCH.casefold(), by_file[PATCH]["RelationshipRef0000"]["formId"].upper())], reverse
    # Many repeated forward edges point to the shared door; reverse paging must
    # be stable and unique regardless of the native index's version inclusion.
    shared = by_file[BASE][SHARED]
    reverse_small, reverse_pages = drain(client, "records.referenced_by", "hits", {**shared, "limit": 1})
    reverse_large, _ = drain(client, "records.referenced_by", "hits", {**shared, "limit": 500})
    assert len(reverse_pages) > 1 and len(reverse_small) >= COUNT, reverse_pages
    assert len(set(map(identity, reverse_small))) == len(reverse_small), reverse_small
    assert list(map(identity, reverse_small)) == list(map(identity, reverse_large)), reverse_large
    assert {row["object"]["editorId"] for row in reverse_small} == {f"RelationshipRef{i:04d}" for i in range(COUNT)}, reverse_small
    report["reversePages"] = reverse_pages

    # Perform and restore one real payload edit; invalidate a forward cursor,
    # explicitly save/flush and check independent semantic disk readback.
    current = client.call("records.references", **query)
    leaf = {**by_file[PATCH][LATER], "path": "EDID"}
    value = client.call("elements.get_value", **leaf)["values"]["editValue"]
    client.call("elements.set_value", **leaf, value=value + "Changed", expectedValue=value,
                expectedRevision=client.call("session.get_dirty_state")["mutationRevision"])
    reject(client, "records.references", {**query, "cursor": current["nextCursor"]}, "cursor_invalidated")
    client.call("elements.set_value", **leaf, value=value, expectedValue=value + "Changed")
    restored, _ = read(root)
    assert list(map(identity, restored)) == list(map(identity, small)), restored
    (artifacts / "relationship-steps.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    client.call("session.save", files=[PATCH])
    client.call("session.flush")
    for name, blob in originals.items():
        actual = (overlay / name).read_bytes()
        if name == PATCH:
            assert disk_state(actual) == disk_state(blob), name
        else:
            assert actual == blob, name


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
