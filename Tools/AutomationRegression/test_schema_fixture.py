"""Validate discovery evidence without executing illustrative native mutations."""
import json
import unittest

from itm_fixture import Client as NativeClient
from schema_fixture import discovery, validate_example


def schema(command="reports.cleaning"):
    return {
        "command": command, "schemaAvailable": True, "exampleAvailable": True,
        "prerequisites": "loaded session", "persistence": "dry-run read",
        "argumentSchema": {"type": "object", "required": ["format", "files"],
                           "properties": {"format": {"type": "string", "enum": ["loot", "boss"]},
                                          "files": {"type": "array<string>", "minItems": 1, "maxItems": 8}}},
        "example": {"command": command, "args": {"format": "loot", "files": ["Patch.esp"]}},
    }


class DiscoveryTests(unittest.TestCase):
    def test_command_named_argument_does_not_collide_with_dispatch(self):
        class Client(NativeClient):
            def __init__(self):
                self.request_body = None

            def request(self, text):
                self.request_body = json.loads(text)
                return {"ok": True, "result": {"schemaAvailable": True}}

        client = Client()
        client.call("system.command_schema", command="elements.set_value")
        self.assertEqual(client.request_body, {"command": "system.command_schema",
                                              "args": {"command": "elements.set_value"}})

    def test_complete_example_and_explicit_absence(self):
        value = schema()
        validate_example(value)
        value.pop("example")
        value["exampleAvailable"] = False
        validate_example(value)

    def test_missing_required_argument_and_old_flat_report_example(self):
        for example in ({"command": "reports.cleaning", "args": {"format": "loot"}},
                        {"format": "loot", "files": ["Patch.esp"]}):
            value = schema()
            value["example"] = example
            with self.assertRaises(AssertionError):
                validate_example(value)

    def test_wrong_type_enum_extra_argument_and_bounds(self):
        for args in ({"format": "loot", "files": "Patch.esp"},
                     {"format": "unknown", "files": ["Patch.esp"]},
                     {"format": "loot", "files": []},
                     {"format": "loot", "files": ["Patch.esp"] * 9},
                     {"format": "loot", "files": ["Patch.esp"], "bogus": True}):
            value = schema()
            value["example"]["args"] = args
            with self.assertRaises(AssertionError):
                validate_example(value)

    def test_boolean_flags_and_nested_batch_rows(self):
        value = schema()
        value["argumentSchema"] = {"type": "object", "required": ["flags"], "properties": {
            "flags": {"type": "object", "allowedBooleanKeys": ["esl"]}}}
        for flags in ({"esl": "true"}, {"unknown": True}):
            value["example"]["args"] = {"flags": flags}
            with self.assertRaises(AssertionError):
                validate_example(value)
        value["argumentSchema"] = {"type": "object", "required": ["items"], "properties": {
            "items": {"type": "array<object>", "itemSchema": {
                "required": ["mode", "target"], "properties": {
                    "mode": {"type": "string", "enum": ["replace"]}, "target": {"type": "object"}}}}}}
        value["example"]["args"] = {"items": [{"mode": "replace"}]}
        with self.assertRaises(AssertionError):
            validate_example(value)

    def test_false_availability_must_not_retain_example(self):
        value = schema()
        value["exampleAvailable"] = False
        with self.assertRaises(AssertionError):
            validate_example(value)

    def test_discovery_queries_only_schema_endpoints_and_keeps_gaps(self):
        class Client:
            def __init__(self):
                self.calls = []

            def call(self, command, /, **args):
                self.calls.append((command, args))
                if command == "system.capabilities":
                    return {"commands": ["records.copy_into", "system.command_schema",
                                         "reports.cleaning", "scripts.run"]}
                if args["command"] == "scripts.run":
                    return {"command": "scripts.run", "schemaAvailable": False,
                            "exampleAvailable": False, "reason": "not authored"}
                return schema(args["command"])

        client = Client()
        result = discovery(client)
        self.assertEqual(result["missing"], ["scripts.run"])
        self.assertFalse(result["nativeMutationTestsRun"])
        self.assertEqual({call[0] for call in client.calls}, {"system.capabilities", "system.command_schema"})


if __name__ == "__main__":
    unittest.main()
