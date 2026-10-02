"""Exercise command discovery and optimistic element editing in a live daemon."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client
from string_fixture import PLUGIN, VALUES

NAME = "AutomationStringLong"
REPLACEMENT = "SchemaExpectedEdit"


def locator(client):
    listing = client.call("records.list", file=PLUGIN, signature="MESG")
    match = next(entry for entry in listing["records"]
                 if entry["object"]["editorId"] == NAME)
    return {**match["locator"], "path": "DESC"}


def exercise(client):
    schema = client.call("system.command_schema", command="elements.set_value")
    assert schema["schemaAvailable"], schema
    assert {"file", "formId", "value"} <= set(schema["argumentSchema"]["required"]), schema
    assert "stale_revision" in schema["errors"] and "stale_value" in schema["errors"]
    flags = client.call("system.command_schema", command="files.set_header_flags")
    assert set(flags["argumentSchema"]["properties"]["flags"]["allowedBooleanKeys"]) == {
        "esm", "esl", "small", "medium", "localized"}, flags
    unknown = client.call("system.command_schema", command="records.copy_into")
    assert unknown["schemaAvailable"] is False, unknown

    target = locator(client)
    capabilities = client.call("elements.edit_capabilities", **target)
    assert capabilities["operations"]["setValue"], capabilities
    assert capabilities["valueConstraint"]["editType"], capabilities
    before = client.call("elements.get_value", **target)["values"]["editValue"]
    assert before == VALUES[NAME], before
    revision = capabilities["mutationRevision"]
    assert revision == client.call("session.get_dirty_state")["mutationRevision"]

    def rejected(expected_revision, expected_value, code):
        request = json.dumps({"command": "elements.set_value", "args": {
            **target, "value": REPLACEMENT, "expectedRevision": expected_revision,
            "expectedValue": expected_value}})
        response = client.request(request)
        assert response["error"]["code"] == code, response
        assert client.call("elements.get_value", **target)["values"]["editValue"] == before

    rejected("0" if revision != "0" else "1", before, "stale_revision")
    rejected(revision, "stale value", "stale_value")
    result = client.call("elements.set_value", **target, value=REPLACEMENT,
                         expectedRevision=revision, expectedValue=before)
    assert result["changed"] and result["readback"]["editValue"] == REPLACEMENT, result
    assert result["mutationRevision"] != revision, result
    assert client.call("elements.get_value", **target)["values"]["editValue"] == REPLACEMENT
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
        assert client.call("elements.get_value", **locator(client))["values"]["editValue"] == REPLACEMENT


if __name__ == "__main__":
    main()
