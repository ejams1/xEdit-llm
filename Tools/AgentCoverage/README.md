# Agent operation inventory

This implements review issue [#8](https://github.com/ejams1/xEdit-llm/issues/8)
without changing the daemon contract or native xEdit behavior. Python 3.12 and
the standard library are sufficient; no game installation or Delphi is needed.

```text
python Tools/AgentCoverage/generate.py
python Tools/AgentCoverage/generate.py --check
python -m unittest discover -s Tools/AgentCoverage -p test_generate.py -v
```

The generator writes the root `AUTOMATION-COVERAGE.md` and `coverage.json` here.
`routes.json` holds manually reviewed routes, effects, limitations and remaining
implementation families. `review-issues.json` records the 18 issues created from
the approved review, including their URLs. The GitHub workflow runs extraction
tests and the drift check on relevant changes.

When adding an operation, update its route/effect metadata and regenerate both
artifacts. New GUI handlers or child forms remain unassessed until mapped; new
registered operations need explicit effect metadata. Removed mappings, unknown
command/job references, denied script primitives, ledger count mismatches and
generated artifact drift fail validation. `--list-gui` prints main-form bindings
to help map new handlers.

The JSON provides native visibility/enable expressions and implementation
locations, all script-policy entries, and an exact symbol/action join for literal
xEdit JvI adapter registrations. Denials outrank allowances. A symbol's presence
does not certify a complete script recipe, native guard behavior or GUI parity.

This is a source-union inventory, including conditional-build branches. It does
not evaluate Delphi game predicates or external-component inheritance. The
document explicitly lists the event/registration extraction scope. Keep runtime
verification pending until supported games and fixture requests have actually
been exercised; writes need fresh-process persistence readback.

The gap backlog groups missing/partial workflows rather than counting each menu
binding as a new implementation task. UI presentation controls and obsolete
actions remain visible in the inventory but do not imply new plugin operations.
