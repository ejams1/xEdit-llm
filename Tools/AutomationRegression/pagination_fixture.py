"""Drain cursor pages, detect missing/duplicate records and stale continuations."""
import argparse
from pathlib import Path
from itm_fixture import Client


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
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    client = Client(args.exe, args.pid, args.artifacts)
    query = {"file": "AutomationItmOverride.esp", "signature": "KYWD"}
    small, pages = drain(client, "records.list", "records", dict(query, limit=2))
    large, _ = drain(client, "records.list", "records", dict(query, limit=500))
    identity = lambda r: (r["object"]["fileName"], r["object"]["formId"])
    assert list(map(identity, small)) == list(map(identity, large))
    assert len({identity(r) for r in small}) == len(small)
    assert len(pages) > 1
    assert pages[0]["nextCursor"]
    client.call("records.create", file=query["file"], signature="KYWD",
                editorId="AutomationCursorInvalidation")
    import json
    stale = client.request(json.dumps({"command": "records.list", "args": dict(
        query, limit=2, cursor=pages[0]["nextCursor"])}))
    assert stale["error"]["code"] == "cursor_invalidated", stale
    client.call("session.save", files=[query["file"]])
    client.call("session.flush")


if __name__ == "__main__":
    main()
