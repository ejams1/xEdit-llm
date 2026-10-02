"""Generate 1,200 records, drain cursor pages and verify persisted readback."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client, plugin, record, subrecord

PLUGIN = "AutomationPaginationFixture.esp"
COUNT = 1200


def fixture_bytes():
    payload = b"".join(record(b"KYWD", subrecord(b"EDID", f"AutomationPage{i:04d}".encode() + b"\0"),
                              form_id=0x01000800 + i) for i in range(COUNT))
    return plugin(["Fallout4.esm"], payload, record_count=COUNT, next_object_id=0x1000)


def drain(client, command, collection, args):
    observed, pages, cursor = [], [], None
    while True:
        request = dict(args)
        if cursor:
            request["cursor"] = cursor
        result = client.call(command, **request)
        pages.append(result)
        observed.extend(result[collection])
        cursor = result.get("nextCursor")
        if not cursor:
            assert result["complete"], result
            break
        assert len(pages) < 10000, "Cursor failed to advance"
    return observed, pages


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
        with (args.overlay / PLUGIN).open("xb") as stream:
            stream.write(fixture_bytes())
        return
    if args.exe is None or args.pid is None or args.artifacts is None:
        parser.error("Live phases require --exe, --pid and --artifacts")
    client = Client(args.exe, args.pid, args.artifacts)
    query = {"file": PLUGIN, "signature": "KYWD"}
    small, pages = drain(client, "records.list", "records", dict(query, limit=37))
    large, _ = drain(client, "records.list", "records", dict(query, limit=500))
    identity = lambda r: (r["locator"]["file"], r["locator"]["formId"])
    assert list(map(identity, small)) == list(map(identity, large))
    assert len({identity(r) for r in small}) == len(small)
    expected = {f"AutomationPage{i:04d}" for i in range(COUNT)}
    if args.phase == "exercise":
        assert len(small) == COUNT
        assert {r["object"]["editorId"] for r in small} == expected
        assert len(pages) > 30
        assert pages[-1]["scannedTotal"] <= COUNT + 1, pages[-1]
        filtered, filter_pages = drain(client, "records.apply_filter", "hits",
                                       {"files": [PLUGIN], "signatures": ["KYWD"], "limit": 37})
        assert list(map(identity, filtered)) == list(map(identity, small))
        assert filter_pages[-1]["scannedTotal"] <= COUNT + 1
        full = client.call("records.list", **dict(query, limit=37))
        projected = client.call("records.list", **dict(query, limit=37, fields=[],
                                                       includeRelations=False))
        assert [r["locator"] for r in projected["records"]] == [r["locator"] for r in full["records"]]
        assert all(set(r["object"]) <= {"kind", "formId", "path"}
                   for r in projected["records"])
        compact_bytes = lambda value: len(json.dumps(value, separators=(",", ":")).encode("utf-8"))
        assert compact_bytes(projected) < compact_bytes(full)
        (args.artifacts / "projection-size.json").write_text(json.dumps({
            "fullBytes": compact_bytes(full), "projectedBytes": compact_bytes(projected),
        }, indent=2), encoding="utf-8")
        first = client.call("records.list", **dict(query, limit=37))
        assert first["nextCursor"]
        client.call("records.create", targetFile=PLUGIN, signature="KYWD",
                    editorId="AutomationCursorInvalidation")
        stale = client.request(json.dumps({"command": "records.list", "args": dict(
            query, limit=37, cursor=first["nextCursor"])}))
        assert stale["error"]["code"] == "cursor_invalidated", stale
        client.call("session.save", files=[PLUGIN])
        client.call("session.flush")
    else:
        assert len(small) == COUNT + 1
        assert {r["object"]["editorId"] for r in small} == expected | {"AutomationCursorInvalidation"}


if __name__ == "__main__":
    main()
