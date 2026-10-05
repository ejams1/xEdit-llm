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

## Issue #25: injected-reference cleanup

Start `cleaning.cleanup_injected_references` with explicit `target.files` and
`options.records` root locators (1..128 records across at most 32 source files).
Omitted dryRun is true. Every source must have problematic references to exactly
one common injection provider. Optional `options.injectionFile` asserts that
provider. Reference construction, ownership, writable source/provider and full
dependency preflight run over the entire selection before any apply work.
`addRequiredMasters` defaults true; existing provider overrides require explicit
`overwrite:true`. TES3 and translation mode reject; other native schemas retain
their native removal rules.

Apply first preserves the original record as a full same-ID override in the
provider, verifies ownership, then calls native `RemoveInjected(False)` on the
source. False protects the root from deletion, not from edits. Results retain
preserved locators and cleanup outcomes; findings distinguish unresolved
references needing manual review. Jobs yield/cancel between source files.
Both files may need saving, including when a native failure interrupts cleanup
after preservation. Script/result-script/package special cases use native rules.

Run `injected_fixture.py generate --overlay <MO2-mod>`, load both files, then
`exercise --overlay <MO2-mod> --exe <exe> --pid <pid> --artifacts <folder>`.
Relaunch for `verify`. It checks dry-run isolation, preservation of the original
reference list in the provider, removal of only the problematic source entry,
unrelated-reference preservation, both-file dirty state and fresh-process
readback. Add native tests for required/unremovable fields, SCPT/result-script/
PLDT rules, protected/ambiguous/existing targets, missing/later dependencies,
mixed invalid selections and partial failures. Needs testing before merging:
Delphi compilation and MO2-backed acceptance remain pending.

## Issues #23/#24: leveled transformations and idle copies

`records.copy_into` adds `mode:"wrapper"` and `mode:"spawn_rate"`, defaulting
to `dryRun:true` for those modes. Wrapper requires a distinct `editorId` and
returns both its original-ID forwarding list and fresh content locator. The
forwarding list has one entry at level/count 1. Spawn-rate mode retains each
original entry and adds nine full clones with counts 1,1,2,2,2,2,2,3,3;
ownership data is preserved. Existing target overrides, deepCopy/overwrite,
Morrowind/Fallout76 and incompatible schemas reject. Source selections require
1..128 entries; expansion cannot exceed 255 when the schema has LLCT.
New content cannot target an update plugin. Optional dryRun also works for
ordinary new/override modes; their existing default remains apply.

`records.copy_idle_tree` accepts 1..128 explicit `sources` locators,
`targetFile`, `oldModelPrefix`, changed `newModelPrefix`, and an
`editorIdPrefix` or `editorIdSuffix`. It resolves winners, rejects duplicates,
requires one normalized model directory, and preflights the full dependency
set before copying. All new identities are allocated before model and internal
FormID rewrites. Selected links, including native condition fields, remap;
external links remain original. TES4/FO3/FNV numeric IDLE schemas are supported;
later games and Morrowind reject. This command selects an explicit directory
group, matching the native workflow; it does not discover descendants from a
root. Both operations mutate memory until explicit save/flush. Partial errors
retain mutation state and created locators/mappings.

Run `copy_modes_fixture.py fo4 generate --overlay <MO2-mod>`, load its files,
then `fo4 exercise --overlay <MO2-mod> --exe <exe> --pid <pid> --artifacts
<folder>`. Relaunch for `fo4 verify`. It checks forwarding links, original
payload preservation, exact spawn distribution, ownership preservation, dry-run
isolation and retry rejection. Use `fo3` in a Fallout 3 profile for idle winner
selection, internal hierarchy links, external-link preservation and prefix
readback. Native condition links, TES4/FNV schema differences, invalid game,
protected/update targets, missing masters, LLCT expansion refusal and injected
partial failures need separate native tests. Needs testing before merging:
Delphi compilation and all game-backed acceptance are pending.

## Issues #21/#22: FormID plans and scoped reference replacement

`formids.change`, `formids.remap`, `formids.renumber` and `formids.inject`
default to `dryRun:true`. Remap accepts 1..32 `{file,oldFormId,newFormId}`
mappings; renumber takes `file`, `startFormId`, optional `endFormId` and
`formIds` (omitting selection chooses all new records, still capped at 32).
Injection takes `masterFile` and preserves object indices by default;
`preserveObjectIds:false` requires `startFormId` in the master slot.
`updateRefs` defaults true. False intentionally leaves old references in place.
Targets must be base records, never headers or later overrides. Existing loaded
target IDs are collisions, including overlapping renumber ranges and swaps.
Use an unused range. All overrides and selected referrers receive dependency
and writable preflight. Optional `addRequiredMasters:true` permits missing
dependencies only when native load-order/module rules allow them.

`references.replace` accepts 1..32 `{oldFormId,newFormId}` mappings and explicit
`scopeFiles`. Both targets must be loaded. Only in-scope referrers change;
excluded counts are reported. Chains/swaps are rejected to prevent cascading
rewrites. Each request allows at most 1024 referrers (and FormID remap also
1024 overrides). TES3 and translation mode are rejected. Reference-index
construction is a synchronous native prerequisite; these are bounded commands,
not incremental jobs. Apply results list completed record changes, dirty files,
mutation audit and the first partial failure. They remain in memory until save.

Generate `formid_fixture.py generate --overlay <MO2-mod>`, then load both
synthetic files in FO4. Run `exercise --overlay <MO2-mod> --exe <exe> --pid
<pid> --artifacts <folder>`; relaunch and run `verify` with a fresh PID.
Assertions cover dry-run isolation, scoped replacement and reversal, collision
refusal, single change with dependent updates, arbitrary-range renumber,
preserved-index injection and save/reload. Additional native cases must cover
missing-master additions, overrides in later files, locked/protected targets,
light/medium ranges, mapping batches, native partial failures and game gates.
Needs testing before merging: Delphi compilation and game-backed runs are pending.

## Issue #20: circular leveled-list validation

`validation.circular_leveled_lists` is a read-only job over explicit target
files. It runs xEdit's native `wbLeveledListCheckCircular` on winning LVLI,
LVLC, LVLN and LVSP records. Findings include source, root locator, native
message and a bounded ordered `cyclePathNames` array. Summaries report checked
records, cycles and dirty-state change; `jobs.get.progress` advances by target
file. TES3 is rejected because it has no plugin GRUP hierarchy. The native
checker uses transient tags, which the job clears before and after each file
scan; verify GUI tag interactions in the final native pass.

Run `circular_fixture.py generate --overlay <MO2-mod>` and load its FO4 plugin.
Then run `circular_fixture.py exercise --overlay <MO2-mod> --exe <exe>
--pid <pid> --artifacts <folder>`. It expects LVLI/LVLN/LVSP cycles, an
acyclic control, structured paths, one-file progress, and unchanged plugin
dirty state/revision. Test LVLC in a supported older game, duplicate cycles,
cross-file links, multiple target files, cancellation and the TES3 gate in
separate profiles. Native compilation and game-backed runs remain pending.

## Issue #18: command discovery and stale edit expectations

`system.command_schema {"command":"elements.set_value"}` returns an on-demand
argument shape, required fields, an example, prerequisites, persistence and
expected errors. Detailed schemas currently cover element value/native writes,
element capability/value/children reads, records.get, session dirty state,
elements.add_child, files.set_header_flags and both batch commands. Registered
commands without authored detail report `schemaAvailable:false`; this is
explicitly advertised in `system.capabilities`.

`elements.edit_capabilities` now reports the native edit type, resolved value
definition, up to 100 bounded choice labels, resolved reference locator if
available, assign templates, and the current mutation revision. Use
`elements.get_value.values.editValue` for an exact expected value. Any command
can optionally assert `expectedRevision`; element mutation verbs additionally
accept `expectedValue`. A mismatch fails before mutation. Mutation responses
include the resulting revision. `elements.set_value` echoes the actual native
edit-value readback up to 65,536 characters; larger values report a length and
point to `elements.get_value`. Structural edits and sorted-value writes mark
indexed paths invalidated so clients re-resolve locators before further edits.

Run `schema_fixture.py exercise --exe <exe> --pid <pid> --artifacts <folder>`
against a fresh `AutomationStringValues.esp` fixture, then relaunch for
`schema_fixture.py verify`. This covers schema discovery, constraints, stale
revision/value rejection, exact readback and persistence. Add native cases for
enum/flag choices, linked references, template selection, sorted arrays and
every unsupported game predicate before accepting the wider editing contract.
Delphi compilation and game-backed execution remain pending.

## Issue #17: bounded read and edit batches

`batch.read` accepts 1..32 `items`, each with `command` and `args`. The read
allowlist is `records.get`, `elements.get`, `elements.get_value`, and
`elements.children`. Child pages are limited to 50 entries per item; nested
`fields` and `includeRelations` project each response. The entire reply is
capped at 1 MiB. A too-large reply fails without changing loaded plugins.

`batch.edit` accepts 1..16 `elements.set_value` items in at most 256 KiB plus the string
`expectedRevision` from `session.get_dirty_state.mutationRevision`. Each item
requires `expectedValue` and `value`; all targets must be owned, writable and
match their expected values before the first write. The batch allows one edit
per record so a sorted container cannot move a later path. Apply follows input
order, returns each completed result, and reports the failing index plus a
native mutation audit if a setter fails after earlier writes. Edits remain in
memory until `session.save` and terminal `session.flush`.

Generate `AutomationStringValues.esp` with `string_fixture.py generate`, then
run `batch_fixture.py exercise --exe <exe> --pid <pid> --artifacts <folder>`
on a fresh MO2-backed daemon. After the save/flush exit, relaunch and run
`batch_fixture.py verify` with a fresh PID. It checks preflight rejection of
a stale later item, two-record apply, revision rejection, batched full reads,
and fresh-process persistence. Test mixed files, different nested child pages,
oversized values and a native failure injected on the second edit separately.
Compilation and game-backed execution remain pending.

## Issue #26: delta patches

`patches.delta` takes `sourceFile` (saved loaded baseline), `comparePath` (external
newer plugin), and `outputFile` (new simple `.esu` filename in the runtime Data
view). `dryRun` defaults true and inspects only headers and dependencies; it
cannot predict record outcomes without loading the comparison. Apply requires
consent and edit mode, immediately copies the newer plugin to disk, and loads
that copy through native delta mode. `markRemovedDeleted` and `removeIdentical`
default true. The baseline stays unchanged. Delta edits require `session.save`
and terminal `session.flush`; before saving, the disk copy is the full comparison.
A failed apply reports its phase and retained disk/session state without rollback.

Inputs are bounded to 1000 records per file and 64 MiB for the comparison.
TES3, localized plugins and comparison `.cpoverride` sidecars reject. Comparison
masters must already be loaded before the baseline. Cleanup compares exactly
the selected baseline, including all header flags, and retains ancestors with
children. Different master tables conservatively retain uncertain records.

Generate `delta_fixture.py generate --overlay <MO2-mod-folder>`. Load Fallout4.esm,
AutomationDeltaMaster.esm and AutomationDeltaBaseline.esp; keep the generated
comparison outside the active load list. Run `exercise` with the same overlay,
exe, PID and artifacts arguments. It asserts dry-run isolation, immediate disk
copy, flag/payload changes, a reversion to an older master, deletion markers,
new records, duplicate-output refusal and unchanged baseline; then saves/flushes.
Relaunch with AutomationDeltaOutput.esu appended and run `verify`. Also verify
changed master-order references, child-group ancestor retention, both options
false, unsupported modes, capacity gates and partial native-load failures before
acceptance. Delphi compilation and game-backed execution remain pending.

## Issue #27: merged patches

`patches.merge` takes `records` (1..32 root locators), `targetFile` (empty loaded
plugin after all contributing files), and `dryRun` (default true). The explicit
record selection uses each record's full loaded override chain. It supports
TES4/FO3/FNV native list families; modern games, which the native GUI warns are
unsupported, reject before mutation. Plans are bounded by 128 overrides per
record, 512 entries per list and 16384 inspected entries across the request.

Planning uses each override's declared-master baseline, applies list additions,
removals and duplicate multiplicities, and handles FLST sets and append-only
OrderedList suffixes. Faulty ordered lists and deleted participants skip the
entire record. Apply copies the whole winning record to preserve unrelated
fields, rewrites differing lists/counts, updates references and cleans target
masters. All plans finish before the first write. Results expose each winner,
list counts, skip/planned/applied outcomes, apply attempts and failure phase/index.
Edits require explicit `session.save` and terminal `session.flush`.

Generate `merged_fixture.py generate --overlay <MO2-mod-folder>` for FO3, load
Fallout3.esm followed by AutomationMergeBase.esm, AutomationMergeLeft.esp,
AutomationMergeRight.esp and AutomationMergeOutput.esp. Run `exercise`, relaunch
with the same order after save/flush, then `verify`. The fixture covers independent
sibling baselines, removal of duplicate entries, independent additions, winning
scalar preservation, ownership payloads, FLST sets, ordered appends and faulty
reorder skips. Also test TES4/FNV-specific families, different declared-master
baselines, single/no-difference overrides, capacity/target refusals, unsupported
modern modes and native partial failures before acceptance. Delphi compilation
and game-backed execution remain pending.

## Issue #28: SEQ export

`exports.seq` takes `file` and an absolute `outputPath` in an existing directory.
The output basename must match the plugin with `.seq` extension. `dryRun` defaults
true and `overwrite` defaults false. The Skyrim family gate and native eligibility
are preserved: skip load-order zero; select direct QUST records with SGE set and
no master or a master with SGE clear. Native FixedFormIDs and record order are
preserved, including the native absence of a separate Deleted exclusion.

Output is headerless little-endian u32 IDs, bounded to 1000 eligible quests after
scanning at most 10000. Apply stages/flushed bytes and atomically renames with the
requested overwrite policy. Failures report remaining temporary state. No eligible
quests leave existing output intact. Plugin data is unchanged; generation reads
loaded memory, so unsaved source edits need a separate plugin save if intended.

Generate `seq_fixture.py generate --overlay <MO2-mod-folder>` for Skyrim. Load
Skyrim.esm, AutomationSeqDummy.esm, AutomationSeqBase.esm, AutomationSeqPatch.esp
in that order: the dummy ensures load-order and file-local IDs differ. Run
`exercise` with the overlay/exe/PID/artifact arguments, then `verify` independently
without a running daemon. It decodes exact bytes, tests master SGE transitions,
new/non-SGE/deleted quests, overwrite refusal/replacement, empty and load-order-zero
skips, preserved old output and unchanged plugin dirty state. Before acceptance,
also test unsupported modes, absent DNAM, disabled overrides, Unicode paths,
capacity refusals and unwritable/racing output destinations. Delphi compilation
and game-backed execution remain pending.

## Issue #29: native LOD jobs

Start `jobs.start` with `kind:"lod.generate"`, `target.worldspaces` containing
1..4 WRLD root locators, `dryRun` (default true), and options `outputRoot` (existing
absolute directory <=160 characters), `operation:"generate"|"splitAtlas"`, and
`objects`/`trees` booleans. Defaults select objects and, where supported, traditional
trees. Each `jobs.get` advances one worldspace; `jobs.cancel` works between worlds.
A native unit blocks that poll and cannot be canceled through the same pipe while
it runs. Completed output remains on cancellation/failure.

Generation supports native TES4, Skyrim, FO3/FNV and FO4 routes. FO76/Starfield
reject. SSE/VR/EnderalSE objects require `-lodgen` startup; serve startup now keeps
those definitions while suppressing the automatic modal generator. Traditional
tree LOD and split support Skyrim/FO3/FNV. Inherited-parent LOD worlds, missing or
out-of-range LOD settings and unsafe EDIDs reject before writing. Output always
uses a fresh per-world directory, so existing outputs are refused; choose another
root to regenerate. Native plugins stay unchanged and need no export save/flush.

`options.settings` accepts object-atlas width/height (1024,2048,4096,8192), object
texture size (256,512,1024), tree brightness (-30..30), object alpha threshold
(0..255), trees3D/noTangents/noVertexColors booleans, and object lodLevel (4,8,16)
with optional paired int16 x/y chunk coordinates. FO3/FNV retain native forced
atlas/UV/vertex-color settings. FO4 explicitly uses native 4096/DXT5/BC5/UV1.1
defaults; settings live in memory and do not rewrite the user's INI. Terrain and
all GUI/external option presets are outside this initial route.

Native stages now rethrow in automation mode, separate scratch from tools/input,
route the 3D-tree disabling LST into the output root, check image-save failures,
and bound relevant reference/billboard/split/material/SCOL work. Split validates
LST/BTT counts, canonical indexes, rectangles and DDS dimensions. Native process
command storage handles long command lines and initializes cancellation status.
Logs and inventories are bounded. Results distinguish planned, failed, no-output
and generated-needs-independent-verification; native return alone is not proof of
valid LOD. `system.capabilities.supports.lod` describes the arguments/limits.

Generate `lod_fixture.py generate --overlay <MO2-mod-folder>` for Skyrim, load
Skyrim.esm followed by AutomationLODScene.esp, and run `exercise` with overlay,
exe, PID and artifacts arguments. Independent `verify` decodes LST/BTT dimensions,
reference identity/position/scale, DDS dimensions/red pixels and split sidecars.
The scene covers tree generation, BTT-associated split exports, unassociated
fallback exports, malformed/permuted/duplicate indexes, empty worlds, dry run,
existing-output refusal and cancellation after one world. No plugin writes occur.

Before acceptance, compile LiteDebug and run this fixture through MO2, then add/run
TES4/FO3/FNV/FO4 object scenes with actual LODGen tools and independently decoded
NIF output. Verify tool failure, SSE LODGen serve startup, level-only/chunk options,
SCOL/material/billboard limits, unsupported games, unwritable/racing output roots,
resource corruption and restoration of every native global. Delphi compilation
and all game/tool-backed execution remain pending.

### Global native reachability (#30)

`analysis.reachability` is a staged job. `target.files` contains 1..32 loaded report plugins with <=1000 total records; `target.roots` optionally contains <=32 additional record-root locators. Native roots are always included. Every loaded plugin participates in the reference -> global reset -> native root pass, before optional roots and report stages. TES3 rejects; other games use native record definitions/rules. Loaded graph limit: 256 files/1000000 records; native reset/reach visit limit: 5000000 per stage. One stage/file per poll; a native unit blocks its current poll.

Default dry run returns the stage plan without changing flags. Explicit `dryRun:false` changes derived memory flags only, with cache writes suppressed and no plugin save. Findings classify the native aggregate override-chain identity; they are historical results valid only when the containing job succeeds. Canceled/failed passes cannot be used as unreachable classifications. Rerun after graph edits or a fresh session; GUI ReachableBuild is enabled only after the complete stage.

Generate `reachability_fixture.py generate --overlay <dedicated-MO2-overlay>`, load Fallout4.esm + AutomationReachBase.esm + AutomationReachRoot.esp, then run `exercise --overlay ... --exe <canonical-built-tool> --pid <broker-pid> --artifacts <artifact-dir>`. It checks a later plugin's native DFOB root reaching an earlier FLST cycle, an isolated cycle remaining unreachable, repeated builds, temporary explicit roots and their removal, cancellation and unchanged dirty state. Native NoReach fields, winner-link edits, malformed scopes, capacity failures and other supported game definitions also require final testing. Python fixture checks are not native acceptance.
