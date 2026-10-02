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

## Issues #5/#6/#7: bounded pipe exchanges and replay

Requests and responses have a 4 MiB encoded UTF-8 limit, independent of the
64 KiB pipe buffers. One WriteFile remains one framed message. Oversized requests
are rejected before dispatch; oversized outcomes return a bounded size error
that states whether dispatch occurred. Server read/write deadlines are 15 seconds,
peer-close is 3 seconds, and the relay's absolute response deadline is 60 seconds.
The VCL timer only polls overlapped I/O; it never flushes or waits for a peer.
Native command execution itself remains on the main thread and is not preempted.

An optional top-level `idempotencyKey` (1–128 UTF-8 bytes) retains the final
response before delivery. Retry the exact original UTF-8 request: correlation,
whitespace and property order changes conflict. Keys are case sensitive. Replay
is confined to the active daemon session, with FIFO limits of 128 entries and
32 MiB encoded request/response retention. Eviction or process exit ends the
protection. Never retry an uncertain unkeyed mutation automatically. Capabilities
publish limits, active session identity and replay guarantees.

`pipe_fixture.py --exe <new-xEdit.exe> --pid <MO2-daemon-pid> --artifacts <folder>`
requires the loaded string fixture. It tests exact and excessive request byte
limits, stalled/nonreading peers and lost-response create replay, verifies that
exactly one KYWD exists, then saves/flushes. The raw PowerShell probe bypasses the
relay's admission check to reach server boundaries. Relaunch and read KYWDs to
prove persistence. Additional required cases: malformed UTF-8/JSON, partial
failure replay, oversized response replay, response larger than 64 KiB, eviction,
repeated cancel/disconnect handle counts, native commands pumping shutdown,
client read/write timeout certainty and terminal flush response delivery.
These native tests and Delphi compilation remain pending.

## Daemon lifecycle

Status: launch flags and request shapes checked against source; native execution
of queued fixes is **pending testing**. Windows, a licensed Delphi 12 setup with
README dependencies, a fresh LiteDebug Win32 executable, and an installed game
under a mod-manager VFS are required. Fixtures redistribute no game data. Use
isolated enabled mod overlays, explicit load order, output routing and backups.
Do not use physical game Data as a fixture directory. A release executable does
not contain these queued source changes unless rebuilt from their exact commit.

A source-backed launch contract, executed through your mod-manager broker, is:

```text
xEdit.exe -FO4 -automation-serve -IKnowWhatImDoing -D:<absolute-game-Data-with-trailing-backslash> -P:<absolute-fixture-plugins.txt>
```

`-FO4` selects the game; `-P:` selects the plugin list. Include Fallout4.esm and
the appropriate synthetic fixture plugins in their dependency order. The current
local skill's reference MO2 broker appends `-automation-serve` and `-P:` itself;
use that broker rather than invoking xEdit outside its VFS. Substitute your
configured broker paths only after validating the actual game/VFS/profile.
Startup may rebuild caches. Readiness requires a successful relay call to
`system.ping` **and** the fixture's presence in `files.list`. Check
`system.describe` for the intended game/Data and `system.capabilities` for the
available command/limits. Discover the process PID from the broker launch result.
The daemon serves `\\.\pipe\xedit-<PID>` after loading.

Write a UTF-8 request file, then use the native relay (each call writes one
response JSON file; inspect `ok` and `error`, not only the relay exit code):

```text
xEdit.exe -automation-call-pid:<PID> -automation-call-request:<absolute-request.json> -automation-call-response:<absolute-response.json>
```

Useful request sequence:

```json
{"command":"system.describe","args":{}}
{"command":"files.list","args":{}}
{"command":"elements.get_value","args":{"file":"AutomationStringValues.esp","formId":"<loaded-form-id>","path":"DESC"}}
{"command":"session.save","args":{"files":["AutomationStringValues.esp"]}}
{"command":"session.get_dirty_state","args":{}}
{"command":"session.flush","args":{}}
```

Verify the intended values before saving. Require `dirty:false` after saving;
check pending save entries because a clean graph may still await final rename.
`session.flush` releases the graph, drains pending renames and exits the daemon.
Require zero `pendingRemainingCount` and successful per-file rename results.
A flush error may also be terminal. Do not send another loaded-data call to that
PID. Relaunch through the same broker under a fresh PID and read the actual
persisted fields; compare them with the intended state and inspect independently
parsed output where the fixture supports it. Avoid force flush for normal tests.

`lifecycle_fixture.py ready|finish|readback --exe <exe> --pid <pid> --file <plugin>
--artifacts <phase-folder> --commit <source-commit> --build-log <compiler-log>`
records executable/transcript hashes and wire artifacts. Readback additionally
requires `--previous-run <finish-folder/run.json>` and a different PID. This
runner covers lifecycle evidence; each feature runner asserts its own semantic
fields. A successful lifecycle smoke test alone does not accept every feature.

`pagination_fixture.py` drains a fresh ITM fixture with two-item pages, compares
order/completeness against a large page, checks duplicate identities, mutates and
asserts explicit cursor invalidation, then saves/flushes. Run it after the
pagination PR is included, separately from ITM-cleaning runs that remove records.
Also drain forward/reverse references with repeated edges, recursion and empty
results, and time large filtered traversals. Retain requests, outcomes, source
commit, build transcript, executable hash, fixture load order, MO2 profile/output
routing and fresh-process readbacks per test. CI runs Python fixture checks and
the operation inventory only; it has neither proprietary Delphi nor game assets.

## Issues #12/#13/#15/#16: complete query paging and compact projection

`records.list`, `records.apply_filter`, `records.references` and
`records.referenced_by` accept `limit` and an opaque `cursor`. Drain until
`complete:true`; a scan-budget page may contain zero records and a nonempty
`nextCursor`. The cursor retains raw file/record or relationship traversal
position, returns `scanned`, `scannedTotal`, `emittedTotal`, revision and
completeness, and never repeats already-scanned filter predicates. A token is
consumed per page. If a response is lost, retry the exact request with the
same idempotency key; old tokens otherwise return `cursor_invalidated`.
Changing query arguments, projection or page size invalidates continuation.
Native plugin mutation, GUI language/ModGroup/reachable/ref-index changes,
expired tokens and terminal flush also invalidate cursors. The cache retains
at most 32 queries, 64 MiB of accounted state, with a five-minute idle expiry.
Reverse relations require the loaded-file reference index; missing index is an
explicit prerequisite error, not an empty complete answer. Recursive outgoing
references use native child-override selection, never a transitive graph walk.
The native selection helper eagerly sorts recursive child roots before paging;
large recursive roots require further profiling in the game-backed test pass.

`records.apply_filter` retains strict 1..100 page sizes and legacy `offset`.
`nextOffset` is emitted only for a nonempty continuation page. New clients
should use `nextCursor`: offset requests repeat earlier predicate work.
Regex patterns are at most 256 characters. A match gets at most 100 ms and a
filter page gets 250 ms or 1,000 match attempts. Timeout, worker-capacity and
request-budget cases return `complete:false`, `incomplete:true` and a reason,
ending that query without treating an unknown candidate as a nonmatch. Workers
cannot be forcibly canceled in this RTL; inspect their lingering-capacity case.

All command responses are compact JSON. Optional `fields` selects summary
fields from a validated allowlist, and `includeRelations:false` suppresses
relations only on locator+summary wrappers. Locators, result counts, revision,
continuation and incomplete metadata remain. Default responses retain their
existing full summary shape. `pagination_fixture.py generate --overlay <MO2-mod>`
creates 1,200 synthetic Fallout 4 KYWD records. Its `exercise` and `verify`
phases use the usual --overlay/--exe/--pid/--artifacts inputs: drain multiple
list/filter pages, compare every locator/name/order and total scan count,
measure full versus identity-only response bytes, invalidate after mutation,
save/flush, then relaunch and read back all 1,201 records. Run empty/sparse,
recursive child-overrides, duplicate forward/reverse links, missing/rebuilt
reference index, regex pathological patterns and projection of nested element
wrappers in the MO2 test pass. Compilation and these native cases are pending.

## Issue #14: incremental job progress

`jobs.get` advances one target file per request on xEdit's main thread. Its
`progress` object reports completed/total/remaining target files and the next
file. `jobs.findings` and read-only session probes work between steps; loaded
graph mutations, save, flush, and scripts return `job_busy` while a job is
active. `jobs.cancel` retains completed summaries/findings and stops before the
next file. Apply jobs preflight writability of every target before the first
file can change. A retained terminal job releases its native file references.

Run `job_fixture.py --exe <exe> --pid <pid> --artifacts <folder> --files
<small-plugin> <second-plugin>` against two disposable loaded plugins. It
checks one-file advancement, progress, findings paging, safe cancellation,
read-only probes, write blocking, restart, aggregation, and discard. Capture
request timings and inspect dirty state after a separate apply/cancel test;
that test needs a fixture where the first file actually changes. Native work
within a single file is still atomic. Large single-file validation scans,
compaction, and cleaning need finer steppers before latency can be guaranteed.
Compilation and game-backed execution remain pending.
