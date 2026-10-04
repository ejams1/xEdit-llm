"""Validate discovery evidence without executing illustrative native mutations."""
import json
from pathlib import Path
import re
import unittest

from itm_fixture import Client as NativeClient
from schema_fixture import discovery, validate_example, validate_shape
from Tools.AgentCoverage.generate import pascal_code


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

    def test_nested_numeric_option_ranges_types_and_finiteness(self):
        value = schema()
        value["argumentSchema"] = {"type": "object", "required": ["values"], "properties": {
            "values": {"type": "object", "required": [], "minProperties": 1, "properties": {
                "scale": {"type": "number:finite", "minimum": 0, "maximum": 10}}}}}
        for number in (0, 2.5, 10):
            value["example"]["args"] = {"values": {"scale": number}}
            validate_example(value)
        for numbers in ({}, {"scale": -1}, {"scale": 11}, {"scale": True},
                        {"scale": float("nan")}, {"scale": float("inf")}):
            value["example"]["args"] = {"values": numbers}
            with self.assertRaises(AssertionError):
                validate_example(value)

    def test_discovery_rejects_inaccurate_capability_coverage_counts(self):
        class Client:
            def call(self, command, /, **args):
                if command == "session.get_dirty_state":
                    return {"dirty": False}
                if command == "system.capabilities":
                    return {"commands": ["reports.cleaning"], "supports": {"commandSchemas": {
                        "registeredCommands": 1, "coveredCommands": 0, "missingCommands": [],
                        "partialCoverage": False}}}
                return schema(args["command"])

        with self.assertRaises(AssertionError):
            discovery(Client())

    def test_discovery_queries_only_schema_and_dirty_state_endpoints(self):
        class Client:
            def __init__(self):
                self.calls = []

            def call(self, command, /, **args):
                self.calls.append((command, args))
                if command == "system.capabilities":
                    return {"commands": ["records.copy_into", "system.command_schema",
                                         "reports.cleaning", "scripts.run"], "supports": {
                        "jobs": {"kinds": ["validation.check_for_itm"]}, "commandSchemas": {
                            "registeredCommands": 4, "coveredCommands": 4, "missingCommands": [],
                            "partialCoverage": False, "registeredJobKinds": 1, "coveredJobKinds": 1,
                            "missingJobKinds": [], "partialJobKindCoverage": False}}}
                if command == "session.get_dirty_state":
                    return {"mutationRevision": "7", "dirty": False}
                if "kind" in args:
                    value = schema("jobs.start")
                    value.update(jobSchemaAvailable=True, jobKind=args["kind"], exampleAvailable=False)
                    value.pop("example")
                    value["argumentSchema"] = {"type": "object", "required": ["kind", "target"], "properties": {
                        "kind": {"type": "string", "enum": [args["kind"]]},
                        "target": {"type": "object", "required": ["files"], "properties": {
                            "files": {"type": "array<string>"}}},
                        "options": {"type": "object", "required": [], "properties": {}}}}
                    return value
                return schema(args["command"])

        client = Client()
        result = discovery(client)
        self.assertEqual(result["missing"], [])
        self.assertEqual(result["coveredJobKinds"], ["validation.check_for_itm"])
        self.assertFalse(result["nativeMutationTestsRun"])
        self.assertEqual({call[0] for call in client.calls}, {
            "system.capabilities", "system.command_schema", "session.get_dirty_state"})

    def test_nested_job_required_field_typo_and_duplicates_reject(self):
        for required in (["missing"], ["files", "files"]):
            value = {"type": "object", "required": ["target"], "properties": {
                "target": {"type": "object", "required": required, "properties": {
                    "files": {"type": "array<string>"}}}}}
            with self.assertRaises(AssertionError):
                validate_shape(value)

    def test_every_registered_command_and_final_job_kind_has_authored_descriptor(self):
        root = Path(__file__).resolve().parents[2]
        text = pascal_code((root / "xEdit/xeAutomationCommandsSystem.pas").read_text())
        body = text[text.index("function xeAutomationDescribeExtendedCommand"):
                    text.index("procedure xeAutomationWriteSchemaCoverage")]
        described = set(re.findall(r"SameText\((?:ACommand|lCommand), '([^']+)'", body))
        # The existing selection branch covers exactly these four known routes.
        described.update(("selections.inspect", "selections.copy_into", "selections.remove", "selections.create_group"))
        registered = set()
        for path in (root / "xEdit").glob("xeAutomationCommands*.pas"):
            registered.update(re.findall(r"xeAutomationRegisterCommand\(\s*'([^']+)'", pascal_code(path.read_text())))
        self.assertEqual(registered - described, set())
        final_kinds = text.split("xeAutomationFinalJobKinds:", 1)[1].split(");", 1)[0]
        kinds = set(re.findall(r"'([^']+)'", final_kinds))
        described_kinds = set(re.findall(r"SameText\(AKind, '([^']+)'", body))
        self.assertEqual(kinds - described_kinds, set())


if __name__ == "__main__":
    unittest.main()
