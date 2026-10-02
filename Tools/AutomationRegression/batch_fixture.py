"""Live batch read/edit acceptance on the disposable string-value plugin."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client
from string_fixture import PLUGIN, VALUES

NAMES = ("AutomationStringLong", "AutomationStringWhitespace")
REPLACEMENTS = {NAMES[0]: "Batch replacement one", NAMES[1]: " Batch replacement two "}


def discover(client):
    listing = client.call("records.list", file=PLUGIN, signature="MESG")
    return {entry["object"]["editorId"]: {**entry["locator"], "path": "DESC"}
            for entry in listing["records"]}


def read(client, locators):
    requests = [{"command": "elements.get_value", "args": locators[name]} for name in NAMES]
    result = client.call("batch.read", items=requests)
    assert result["complete"] and result["total"] == 2, result
    assert [item["index"] for item in result["items"]] == [0, 1], result
    return {name: item["result"]["values"]["editValue"]
            for name, item in zip(NAMES, result["items"])}


def edit_items(locators, expected):
    return [{"command": "elements.set_value", "args": {
        **locators[name], "expectedValue": expected[name], "value": REPLACEMENTS[name]}}
        for name in NAMES]


def exercise(client):
    locators = discover(client)
    assert set(NAMES) <= set(locators), locators
    observed = read(client, locators)
    assert observed == {name: VALUES[name] for name in NAMES}, observed
    revision = client.call("session.get_dirty_state")["mutationRevision"]

    # A bad later expectation must reject the whole batch before item zero writes.
    wrong = edit_items(locators, observed)
    wrong[1]["args"]["expectedValue"] = "stale"
    denied = client.request(json.dumps({"command": "batch.edit", "args": {
        "expectedRevision": revision, "items": wrong}}))
    assert denied["error"]["code"] == "stale_value", denied
    assert read(client, locators) == observed

    edited = client.call("batch.edit", expectedRevision=revision,
                         items=edit_items(locators, observed))
    assert edited["complete"] and edited["completed"] == 2, edited
    assert edited["changed"] and edited["persistence"] == "in-memory-until-session.save", edited
    assert [entry["index"] for entry in edited["items"]] == [0, 1], edited
    assert read(client, locators) == REPLACEMENTS
    stale = client.request(json.dumps({"command": "batch.edit", "args": {
        "expectedRevision": revision, "items": edit_items(locators, observed)}}))
    assert stale["error"]["code"] == "stale_revision", stale
    client.call("session.save", files=[PLUGIN])
    client.call("session.flush")


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("exercise", "verify"))
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    client = Client(args.exe, args.pid, args.artifacts)
    if args.phase == "exercise":
        exercise(client)
    else:
        assert read(client, discover(client)) == REPLACEMENTS


if __name__ == "__main__":
    main()
