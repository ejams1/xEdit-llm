"""Fixture integrity and acceptance assertion checks; no Pascal runtime evidence."""
from copy import deepcopy
import struct
import unittest

from report_fixture import signatures
from row_fixture import disk_state
import subtree_fixture as fixture


def snapshot(complete=True):
    root = {"file": fixture.SCENE, "formId": "02001100", "path": ""}
    child = {**root, "path": "[0]"}
    return {"root": root, "nodes": [
        {"locator": root, "object": {"kind": "record"}, "depth": 0,
         "parentIndex": -1, "childSlots": 1, "complete": complete},
        {"locator": child, "object": {"kind": "element"}, "depth": 1,
         "parentIndex": 0, "childSlots": 0 if complete else 1, "complete": complete}],
        "count": 2, "complete": complete, "truncated": not complete,
        "truncationReasons": [] if complete else ["maxDepth"],
        "visitedUnits": 3, "order": "preorder", "nativeCallsPreemptible": False,
        "limits": {"maxNodes": 256, "maxDepth": 8, "visitLimit": 1024, "responseBytes": 1048576}}


class SubtreeFixtureTests(unittest.TestCase):
    def test_counts_and_ids_and_independent_reference_payloads(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            roots = signatures(blob, 24)
            self.assertEqual(struct.unpack_from("<I", blob, 34)[0], len(roots) - 1, name)
            self.assertEqual(len({identity for _, identity, _ in roots}), len(roots), name)
        masters, rows = disk_state(data[fixture.SCENE])
        self.assertEqual(masters, ["Fallout4.esm", fixture.BASE])
        references = rows["SubtreeDenseArray"]["fields"][b"LNAM"]
        self.assertEqual(len(references), fixture.DENSE_ARRAY)
        self.assertEqual([struct.unpack("<I", r)[0] for r in references],
                         [0x01000800 + i % fixture.KEYWORDS for i in range(fixture.DENSE_ARRAY)])
        self.assertEqual(rows["SubtreeEmpty"]["fields"][b"KWDA"], [b""])
        self.assertEqual(len([sig for sig, _, _ in signatures(data[fixture.SCENE], 24) if sig == b"REFR"]), 84)
        self.assertEqual(len(rows["SubtreeUnicode"]["fields"][b"ITXT"]), 50)
        self.assertIn("界".encode("utf-8"), data[fixture.SCENE])

    def test_cell_groups_follow_native_decimal_labels(self):
        blob = fixture.fixtures()[fixture.SCENE]
        seen = []

        def visit(start, end, parents=()):
            while start < end:
                signature, size = struct.unpack_from("<4sI", blob, start)
                if signature == b"GRUP":
                    label, kind = struct.unpack_from("<II", blob, start + 8)
                    visit(start + 24, start + size, parents + ((label, kind),))
                    start += size
                else:
                    if signature == b"CELL":
                        identity = struct.unpack_from("<I", blob, start + 12)[0] & 0xFFFFFF
                        seen.append(identity)
                        self.assertEqual(parents[-2:], ((identity % 10, 2), (identity // 10 % 10, 3)))
                    start += 24 + size
            self.assertEqual(start, end)
        visit(0, len(blob))
        self.assertEqual(seen, [0x3000, 0x4000])

    def test_assertions_accept_complete_and_partial_topology(self):
        for complete in (True, False):
            fixture.validate_subtree(snapshot(complete))
        for reason in ("maxNodes", "maxDepth", "visitLimit", "responseBytes"):
            value = snapshot(False)
            value["truncationReasons"] = [reason]
            fixture.validate_subtree(value)

    def test_assertions_reject_false_completeness_topology_and_limit_overruns(self):
        for mutate in (
            lambda s: s.update(count=3),
            lambda s: s.update(truncationReasons=["maxDepth"]),
            lambda s: s.update(visitedUnits=1025),
            lambda s: s["nodes"][1].update(parentIndex=1),
            lambda s: s["nodes"][1].update(depth=9),
            lambda s: s["nodes"][0].update(complete=False),
            lambda s: s["nodes"][1]["locator"].update(path=""),
            lambda s: s.update(nativeCallsPreemptible=True),
            lambda s: s["nodes"][1]["object"].update(value="界" * 400000),
        ):
            value = deepcopy(snapshot())
            mutate(value)
            with self.assertRaises(AssertionError):
                fixture.validate_subtree(value)
        partial = snapshot(False)
        partial["nodes"][0]["complete"] = True
        with self.assertRaises(AssertionError):
            fixture.validate_subtree(partial)

    def test_hints_cannot_claim_complete_after_a_partial_sibling_scan(self):
        value = snapshot()
        value["nodes"][1]["object"] = {"kind": "child_group", "count": 80,
                                       "signatureScanCount": 32, "signatureScanLimit": 32,
                                       "signaturesComplete": False}
        fixture.validate_subtree(value)
        value["nodes"][1]["object"]["signaturesComplete"] = True
        with self.assertRaises(AssertionError):
            fixture.validate_subtree(value)

    def test_old_page_reference_walk_orders_virtual_group_after_all_payload_pages(self):
        root = {"file": "Fixture.esp", "formId": "01000800", "path": ""}
        virtual = {"locator": {**root, "path": r"\Child Group"}, "object": {"kind": "child_group"}}

        class Client:
            def call(self, command, /, **args):
                self.assertions(command, args)
                count = 40
                page = [{"locator": {**root, "path": f"[{i}]"}, "object": {"kind": "element"}}
                        for i in range(args["offset"], min(count, args["offset"] + args["limit"]))]
                if args["offset"] == 0:
                    page.append(virtual)
                return {"children": page, "truncated": args["offset"] + args["limit"] < count}

            @staticmethod
            def assertions(command, args):
                assert command == "elements.children" and args["limit"] == 37

        rows = fixture.immediate_children(Client(), root)
        self.assertEqual([row["locator"]["path"] for row in rows], [f"[{i}]" for i in range(40)] + [r"\Child Group"])


if __name__ == "__main__":
    unittest.main()
