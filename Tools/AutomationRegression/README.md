# Automation regression fixtures

Python 3.12 source/fixture checks (no Delphi or game required):

```text
python -m unittest discover -s Tools/AutomationRegression -p "test_*.py" -v
```

These checks do not certify Delphi compilation or native runtime semantics.
Every queued fix needs a new LiteDebug build and game-backed acceptance before
merge. Preserve request/response artifacts and executable hash with each run.

## Issue #1: ITM headers

`itm_fixture.py` creates synthetic Fallout 4 plugins without redistributing game
data. Use a dedicated enabled MO2 mod overlay and a load order containing
Fallout4.esm, AutomationItmMaster.esm and AutomationItmOverride.esp. Generation
refuses to overwrite fixtures. Never generate into physical game Data.

```text
python Tools/AutomationRegression/itm_fixture.py generate --overlay <MO2-mod-folder>
python Tools/AutomationRegression/itm_fixture.py exercise --overlay <MO2-mod-folder> --exe <new-xEdit.exe> --pid <MO2-daemon-pid> --artifacts <run-folder>
```

Launch the daemon through the broker-backed MO2 client described in the local
development skill, using the new executable. The runner uses xEdit's native
`-automation-call-*` relay against that existing daemon; it does not launch a game
session. It verifies exact ITM findings, dry-run count and apply count, retained
record ownership, then saves and terminally flushes. Relaunch through MO2 under
a fresh PID and use separate artifact folders:

```text
python Tools/AutomationRegression/itm_fixture.py verify --overlay <MO2-mod-folder> --exe <new-xEdit.exe> --pid <fresh-pid> --artifacts <readback-folder>
python Tools/AutomationRegression/itm_fixture.py disk --overlay <actual-MO2-output-folder>
```

Disk parsing checks retained records and exact flag bits independently of daemon
responses; resolve MO2 overwrite/output routing before choosing that directory.
Also exercise unsaved identical copies, unsaved flag changes after conflict state
is populated, injected records, NAVM benign conflicts, differing master tables
and compressed records. The byte fallback deliberately retains uncertain dirty
records and complex module slots rather than removing them. These live cases and
the checked-in runner have not been run locally: no Delphi/MO2 setup is installed.

## Issues #2/#3: full values and encoding

`elements.get_value` accepts the same file/formId/path locator as `elements.get`.
It returns `values.editValue` without trimming (including empty text), UTF-16
length, UTF-8 byte length, JSON encoding and `truncated:false`. `nativeValue`
identifies the Variant type and returns integers as decimal strings to preserve
64-bit precision, typed scalars, or bounded one-dimensional arrays. Unsupported
Variants are explicitly unavailable. Limits are 1,048,576 UTF-16 characters per
string and 50,000 array items; exceeding a limit returns an error, never a preview.
`storageEncoding` identifies the effective inline encoding; localized table
strings are explicitly distinguished from inline text. Enumeration summaries
remain bounded and now include per-field `previewMetadata` with original length,
truncation, whitespace removal and losslessness. Read full values before editing.

`string_fixture.py` uses the same generate/exercise/verify arguments and MO2
launch arrangement as the ITM runner. Include AutomationStringValues.esp after
Fallout4.esm. It exercises long, empty, whitespace and multilingual DESC values,
checks preview metadata and full native reads, rejects a lossy CP-1252 edit,
edits/saves/flushes, then verifies text under a fresh process.

Before merge, also test signed/unsigned 64-bit native values, float/bool/byte
arrays, full-read limits, fixed-size multibyte fields, explicit per-file CP-1252
and UTF-8 `.cpoverride`/SNAM precedence, per-definition overrides, BOMs and
localized IDs. Autodetected UTF-8 is preserved from the original bytes. When no
UTF-8 evidence remains (e.g. an ASCII-only field), unrepresentable writes are
rejected before resizing. A fixed-size write that would cut encoded bytes is also
rejected. Runtime execution and Delphi compilation remain pending.

## Issues #4/#10: mutation outcomes

`mutation_fixture.py --exe <new-xEdit.exe> --pid <MO2-daemon-pid> --artifacts
<run-folder>` uses the loaded string fixture. It verifies that an unsupported
LAND EditorID fails without mutation and that a script editing an already-dirty
file before a division-by-zero failure reports the actual affected file. It
inspects the complete resulting text before saving and terminally flushing.
Relaunch and independently read DESC to prove persistence.

Create/copy failures expose completed steps, mutation generations, affected files
and remaining-state guidance. Fresh-record rollback is attempted where feasible;
group creation and consumed IDs are not claimed to be fully rolled back. Save
errors include completed, failed and not-attempted file steps, current dirty and
pending-flush state. A failing native disk save can have an unknown partial
outcome. Generic job errors likewise use `partial:null, partialKnown:false` when
no native plugin modification is observed and external writes cannot be ruled
out. Script mutation reporting uses native generations rather than dirty-set
changes. Generations indicate native modification notifications, not byte deltas.

Pending failure injection: native copy refusal after dependencies change; create
failure after Add with rollback success/failure; two-file save with the second
output locked/unwritable; existing WRLD CELL EditorID changes; queued job failure
after an earlier target is processed. Preserve affected master lists, IDs,
groups, dirty/pending state, output files and fresh-process readbacks.
