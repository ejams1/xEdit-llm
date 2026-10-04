"""Exercise command discovery and optimistic element editing in a live daemon."""
import argparse
import json
from pathlib import Path
from itm_fixture import Client
from string_fixture import PLUGIN, VALUES

NAME = "AutomationStringLong"
REPLACEMENT = "SchemaExpectedEdit"


def validate_example(schema):
    """Check only advertised request shapes, never dispatch illustrative edits."""
    assert isinstance(schema.get("exampleAvailable"), bool), schema
    if not schema["exampleAvailable"]:
        assert "example" not in schema, schema
        return
    assert schema["schemaAvailable"], schema
    example = schema["example"]
    assert example.get("command") == schema["command"], example
    assert isinstance(example.get("args"), dict), example

    def validate(value, shape):
        properties = shape.get("properties", {})
        assert set(shape.get("required", [])) <= set(properties), shape
        if isinstance(value, dict):
            assert set(shape.get("required", [])) <= set(value), (value, shape)
            assert set(value) <= set(properties), (value, shape)
            for key, child in value.items():
                field = properties[key]
                kind = field["type"].split(":", 1)[0]
                if kind == "string":
                    assert isinstance(child, str), (key, child)
                elif kind == "boolean":
                    assert isinstance(child, bool), (key, child)
                elif kind == "integer":
                    assert isinstance(child, int) and not isinstance(child, bool), (key, child)
                elif kind == "object":
                    assert isinstance(child, dict), (key, child)
                elif kind.startswith("array"):
                    assert isinstance(child, list), (key, child)
                if "enum" in field:
                    assert child in field["enum"], (key, child)
                if "allowedBooleanKeys" in field:
                    assert set(child) <= set(field["allowedBooleanKeys"]), child
                    assert all(isinstance(flag, bool) for flag in child.values()), child
                if isinstance(child, list):
                    assert len(child) >= field.get("minItems", 0), child
                    assert len(child) <= field.get("maxItems", len(child)), child
                    if "itemSchema" in field:
                        for item in child:
                            validate(item, field["itemSchema"])

    validate(example["args"], schema["argumentSchema"])


def discovery(client):
    """Audit every registered schema and capture explicit coverage gaps."""
    capabilities = client.call("system.capabilities")
    commands = capabilities["commands"]
    assert len(commands) == len(set(commands)), commands
    covered, missing, examples = [], [], []
    for command in commands:
        schema = client.call("system.command_schema", command=command)
        assert schema["command"] == command, schema
        assert isinstance(schema["schemaAvailable"], bool), schema
        if schema["schemaAvailable"]:
            shape = schema["argumentSchema"]
            assert shape["type"] == "object", shape
            assert isinstance(shape["properties"], dict), shape
            assert isinstance(shape["required"], list), shape
            assert set(shape["required"]) <= set(shape["properties"]), shape
            assert schema["prerequisites"] and schema["persistence"], schema
            covered.append(command)
        else:
            assert schema["reason"] and "argumentSchema" not in schema, schema
            missing.append(command)
        validate_example(schema)
        if schema["exampleAvailable"]:
            examples.append(command)
    required = {command for command in commands if command.startswith(("elements.", "jobs."))}
    required |= {"records.copy_into", "system.command_schema", "reports.cleaning"}
    assert required <= set(covered), sorted(required - set(covered))
    return {"covered": covered, "missing": missing, "examples": examples,
            "registeredCount": len(commands), "nativeMutationTestsRun": False}


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
    copy = client.call("system.command_schema", command="records.copy_into")
    assert copy["schemaAvailable"], copy
    assert {"source", "target", "mode"} <= set(copy["argumentSchema"]["required"]), copy

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
    parser.add_argument("phase", choices=("discovery", "exercise", "verify"))
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    client = Client(args.exe, args.pid, args.artifacts)
    if args.phase == "discovery":
        report = discovery(client)
        (args.artifacts / "schema-discovery.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8")
    elif args.phase == "exercise":
        exercise(client)
    else:
        assert client.call("elements.get_value", **locator(client))["values"]["editValue"] == REPLACEMENT


if __name__ == "__main__":
    main()
