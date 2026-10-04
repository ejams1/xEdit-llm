"""Independent fixture integrity and assertion checks; no Pascal execution."""
from copy import deepcopy
import struct
import unittest

from report_fixture import signatures
from row_fixture import disk_state
import relationship_step_fixture as fixture


def snapshot(complete=False):
    return {"hits": [], "count": 0, "limit": 1, "scanned": 5000,
            "scannedTotal": 5000, "emittedTotal": 0, "revision": "1", "semanticRevision": "2",
            "complete": complete, "incomplete": False, "truncated": not complete,
            "cursorRetained": not complete, **({"nextCursor": "opaque"} if not complete else {}),
            "traversal": {"phase": "complete" if complete else "sort-child-roots", "recursive": True,
                "rootSelectionComplete": True, "selectedChildRoots": 700,
                "retainedChildRoots": 0 if complete else 700, "candidateVersions": 934,
                "selectionWork": 3000, "sortWork": 2000, "payloadWork": 0,
                "retainedDepth": 0, "accountedRetainedBytes": 200000, "rootLimit": 100000,
                "selectionWorkLimit": 1000000, "payloadWorkLimit": 100000,
                "pageWorkLimit": 5000, "softPageBudgetMs": 100, "nativeCallsPreemptible": False}}


class RelationshipStepFixtureTests(unittest.TestCase):
    def test_headers_counts_unique_roots_and_independent_payloads(self):
        data = fixture.fixtures()
        for name, blob in data.items():
            rows = signatures(blob, 24)
            self.assertEqual(struct.unpack_from("<I", blob, 34)[0], len(rows) - 1, name)
            self.assertEqual(len({identity for _, identity, _ in rows}), len(rows), name)
            self.assertEqual(struct.unpack_from("<I", blob, 38)[0], 0x7000)
        masters, base = disk_state(data[fixture.BASE])
        self.assertEqual(masters, ["Fallout4.esm"])
        _, patch = disk_state(data[fixture.PATCH])
        self.assertEqual(len([name for name in base if name.startswith("RelationshipRef")]), fixture.COUNT)
        self.assertEqual(len([name for name in patch if name.startswith("RelationshipRef")]), 234)
        for i in range(fixture.COUNT):
            row = base[f"RelationshipRef{i:04d}"]
            self.assertEqual(struct.unpack("<I", row["fields"][b"NAME"][0])[0], 0x01000800 + i)
            teleport = row["fields"][b"XTEL"][0]
            self.assertEqual(len(teleport), 36)
            self.assertEqual(struct.unpack_from("<I", teleport)[0], 0x01006000)
            if i % 3 == 0:
                patched = patch[f"RelationshipRef{i:04d}"]
                self.assertEqual(patched["identity"], row["identity"])
                self.assertEqual(struct.unpack("<I", patched["fields"][b"NAME"][0])[0], 0x01000800 + fixture.COUNT + i)
        self.assertEqual(base[fixture.target(1)]["fields"][b"KWDA"], [struct.pack("<I", 0x01001200)])
        self.assertEqual(struct.unpack("<I", base[fixture.SHARED]["fields"][b"NAME"][0])[0], 0x01001100)

    def test_structural_scope_and_order_differ_from_global_winner(self):
        def structure(blob):
            result = []

            def visit(start, end, parents=()):
                while start < end:
                    signature, size = struct.unpack_from("<4sI", blob, start)
                    if signature == b"GRUP":
                        label, kind = struct.unpack_from("<II", blob, start + 8)
                        visit(start + 24, start + size, parents + ((label, kind),))
                        start += size
                    else:
                        identity = struct.unpack_from("<I", blob, start + 12)[0]
                        result.append((signature, identity, parents))
                        if signature == b"CELL":
                            oid = identity & 0xFFFFFF
                            self.assertEqual(parents[-2:], ((oid % 10, 2), (oid // 10 % 10, 3)))
                        start += 24 + size
                self.assertEqual(start, end)
            visit(0, len(blob))
            return result

        data = fixture.fixtures()
        base = structure(data[fixture.BASE])
        children = [identity for sig, identity, parents in base
                    if sig == b"REFR" and (0x01003000, 6) in parents]
        self.assertEqual(children, [0x01004000 + i for parity in (1, 0)
                                    for i in range(fixture.COUNT) if i % 2 == parity])
        self.assertNotEqual(children, sorted(children))
        self.assertFalse(any((0x01003200, 6) in parents for _, _, parents in base))
        patch = structure(data[fixture.PATCH])
        self.assertTrue(any(sig == b"REFR" and (0x01003200, 6) in parents for sig, _, parents in patch))
        outside = structure(data[fixture.OUTSIDE])
        self.assertFalse(any(identity == 0x01003000 for _, identity, _ in outside))
        moved = [(identity, parents) for sig, identity, parents in outside if sig == b"REFR"]
        self.assertEqual(moved[0][0], 0x01004005)
        self.assertIn((0x01003100, 6), moved[0][1])

    def test_expected_sequence_excludes_transitive_and_outside_targets(self):
        names = fixture.expected_names()
        self.assertEqual(len(names), fixture.COUNT + 2)
        self.assertEqual(len(set(names)), len(names))
        self.assertEqual(names[:5], [fixture.PREFIX, fixture.target(700), fixture.SHARED,
                                   fixture.target(1), fixture.target(2)])
        self.assertNotIn("RelationshipOutsideTarget", names)
        self.assertNotIn("RelationshipNeverFollowedKeyword", names)
        self.assertEqual(len(fixture.expected_names(patch_only=True)), 236)

    def test_assertions_accept_empty_continuation_and_terminal_release(self):
        fixture.validate_page(snapshot())
        fixture.validate_page(snapshot(True), snapshot())

    def test_assertions_reject_limit_overruns_false_completion_and_regression(self):
        for mutate in (
            lambda p: p.update(scanned=5001),
            lambda p: p.update(complete=True),
            lambda p: p.update(cursorRetained=False),
            lambda p: p.update(count=1),
            lambda p: p["traversal"].update(selectionWork=1000001),
            lambda p: p["traversal"].update(selectedChildRoots=100001),
            lambda p: p["traversal"].update(payloadWork=100001),
            lambda p: p["traversal"].update(retainedDepth=129),
            lambda p: p["traversal"].update(nativeCallsPreemptible=True),
            lambda p: p["traversal"].update(accountedRetainedBytes=67108865),
        ):
            page = deepcopy(snapshot())
            mutate(page)
            with self.assertRaises(AssertionError):
                fixture.validate_page(page)
        for mutate in (
            lambda p: p.update(semanticRevision="3"),
            lambda p: p.update(scannedTotal=4999),
            lambda p: p["traversal"].update(phase="select-child-roots"),
            lambda p: p["traversal"].update(sortWork=1999),
        ):
            page = deepcopy(snapshot())
            mutate(page)
            with self.assertRaises(AssertionError):
                fixture.validate_page(page, snapshot())


if __name__ == "__main__":
    unittest.main()
