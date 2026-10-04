# Automation regression fixtures

## Issue #18: command schema discovery audit

On a freshly compiled LiteDebug daemon run:

```powershell
python Tools/AutomationRegression/schema_fixture.py discovery --exe <trusted-exe> --pid <daemon-pid> --artifacts <new-capture-directory>
```

This phase queries capabilities and every registered command schema without
executing the examples. It captures each exchange plus `schema-discovery.json`,
listing authored schemas and available examples. All registered commands and job
kinds must be covered. Capability coverage counts and missing arrays are computed
from the registry and checked against the returned descriptors. Add `kind` when
querying `jobs.start` to discover that kind's nested target/options descriptor:

```json
{"command":"system.command_schema","args":{"command":"jobs.start","kind":"lod.generate"}}
```

The runner also checks that discovery leaves plugin dirty/pending-save state
unchanged. Schema queries for a non-job command with `kind`, or for an unknown job
kind, must fail before descriptor construction.
Discovery checks required arguments, example envelopes, field types/enums, boolean
flag keys and authored nested item schemas. `exampleAvailable:false` means no
example is advertised; illustrative file names/FormIDs and angle-bracket tokens
must be replaced with values from the loaded session before executing any example.
The descriptor vocabulary is an authored protocol shape, not standard JSON Schema.

Contract 0.54 covers all 109 current commands and 17 job kinds, corrects the
`elements.children` schema maximum to the native 1000 and adds `includeParents`.
It exposes the host's optional wire revision precondition and summary projection
arguments, including allowed summary fields from the native projection allowlist.
Nested job descriptors include LOD settings, native ESL options, file hygiene,
selective cleaning, injected-reference cleanup and global analysis scopes, with
their native game/load/persistence constraints. `jobs.get` advances native work and can mutate a plugin or write
external output; it is not a passive status call. Plugin writes still require
explicit save and terminal flush. Descriptors list common errors with
`errorsExhaustive:false`; runtime target-specific predicates still require native
preflight and element capability/choice discovery. A new unauthored command/kind
is reported as missing and fails the complete-discovery acceptance runner.

Then generate a fresh string overlay using `string_fixture.py`, run the existing
`schema_fixture.py exercise` phase with consent, restart the daemon and run
`verify` with a fresh PID/artifact directory. Exercise validates the now-authored
`records.copy_into` schema, optimistic revision/value refusals and edit readback;
verify checks persisted full values. Run with no consent for discovery and inspect
that no plugin dirty state or pending-save state changes. Native build, discovery,
mutations and game-backed persistence have not been run locally; Python checks
only validate the fixture/audit logic.

## Issue #37: multiple structural rows

`batch.rows` accepts `items` (1..16), mandatory `expectedRevision` from
`session.get_dirty_state.mutationRevision`, `dryRun` (default true), and
`addRequiredMasters` (default false). Every item has `mode`, an owned `target`
child locator (`file`, `formId`, `path`), and for copying an owned `source`
child locator. Modes are explicit:

- `replace`: replace an existing payload row with a source of the same native
  definition/type, including replacing a whole array. Union variant switching
  and copying a single member into a whole-array replacement are refused.
- `append`: copy one entry into an existing native array, including packed KWDA
  subrecord arrays. Content-sorted arrays use native ordering.
- `remove`: remove the addressed existing child; omit `source`.

All target/schema/removal/missing-master predicates finish before any write.
Requests are bounded to 256KiB, 2048 total visited source/target elements and
depth16. Targets must be distinct and have no ancestor overlaps; a source record
cannot also be a target in the batch. Multiple siblings in one record are allowed
and native interfaces are pinned so sorting/removal cannot redirect stale indexes.
Record roots/headers, deleted/partial forms, TES3 and translation mode refuse.
There is no missing-ancestor creation or implicit source-absence mirror deletion:
create ancestors explicitly with existing element commands, then enumerate fresh
rows. The coverage profile retains this contextual-copy limitation.

Apply requires consent and only changes plugin memory. Results contain an outcome
for every item (`planned`, `applied`, `failed`, `not-attempted`), `completed`,
`complete`, required masters, mutation audit, and optional partial failure. A
failed item may have changed memory or added masters; no rollback is promised.
Inspect `complete`, not only envelope `ok`. Native assignment errors propagate
through the scoped `wbAutomationAssign` helper, including nested member failures;
successful bulk assignment returning nil is handled separately. Affected records
refresh references. Paths/result locators may move during subsequent items;
re-enumerate after the whole batch. Persistence requires explicit `session.save`
and terminal `session.flush`.

Generate `python Tools/AutomationRegression/row_fixture.py generate --overlay
<fresh-dedicated-MO2-overlay>` and launch through MO2 using its `plugins.txt`:
Fallout4.esm, AutomationRowDependencies.esm, AutomationRowSource.esm,
AutomationRowTargets.esp. Run `exercise --overlay ... --exe <fresh-built-tool>
--pid <daemon-pid> --artifacts <run-dir>`, then restart fresh and run `verify`
with new PID/artifacts. The fixture checks four text replacements across two
records, exact whitespace, whole-array replacement plus missing-master refusal/
addition, two removals despite index shifts, append vs replacement, sorted KWDA
key replacements/removal/append and count updates, actual reference owners,
unchanged identities/unselected fields/source bytes, stale revision, later
protected/missing/invalid targets, overlap/source-target/17-item refusal, and
unchanged disk before save. A MESG flag callback detaches a later planned TNAM:
the earlier flag change is retained, the detached row fails and the final row is
not attempted; an explicit fresh batch recovers. Fresh verification decodes text,
reference master slots, keyword count and retained MISC data. Save can defer final
path replacement until terminal flush; the fresh phase always checks disk bytes.

Use a separate untouched overlay/session without mutation consent for
`no-consent`: dry-run must work and apply must refuse without changes. Before
acceptance also run unsupported game/translation and deleted/partial cases,
union/different-definition refusals, visit/depth/request limits, later-load
dependencies, and injected nested native assignment failures. For partial errors
inspect failed `rowApplied`, retained earlier edits/added masters and untouched
later items; verify strict assignment scope restores after exceptions. Delphi
compilation and all native/MO2 execution remain pending; Python checks only
validate fixture/support assets.

## Issue #36: file/group selections

`selections.inspect/copy_into/remove` take 1..16 `selections`, each either
`{kind:"file",file}` or `{kind:"group",file,groupPath:[{type,label},...]}`.
Inspection emits ready-to-use group selectors. Labels are eight-hex-digit current
native `GroupLabel` values, scoped to the current session; re-inspect after master
edits/reload. Use `expectedRevision` to reject stale mutation requests. Limits:
128 source/implicit owner records, 2048 retained structural nodes and path sibling
visits, depth 8. Duplicate/overlapping selectors and differing source versions of
one FormID reject. TES3 and translation mode reject.

`copy_into` takes later loaded writable `targetFile`, `overwrite:false` and
`addRequiredMasters:true` defaults. `dryRun` defaults true. File/group selections
copy all contained owned records recursively as overrides, excluding the TES4
file header; no new-ID mode is provided. Contextual owner records are planned
before children: explicitly selected owner versions win; an existing target owner
is preserved when not selected; otherwise native highest-visible owners enter
the plan, dependency checks and capacity accounting. Full nondeleted/nonpartial
payloads require native partial-form creation disabled. Empty groups copy as
no-op; use `create_group` to create an empty top-level group. All root-copy
preflights finish before writes; results retain completed/failed identities and
mutation audit. Native ancestors/group context are recreated, with no header clone.

`remove` accepts group selectors, preflights every descendant and removes the
native subtree in memory. Native file objects are non-removable: file removal
refuses without clearing records, unloading modules or deleting disk files.
Unload by restarting with a different plugin list. `create_group` takes `file`,
public enabled top-level `signature` and default `dryRun:true`; existing groups
are no-ops. Native save may omit empty groups; add records before persistence.
Existing `files.create` provides new plugin creation. All apply operations require
consent and retain the explicit plugin save/terminal flush boundary; partial
failure does not roll back completed writes. Group paths may invalidate after edits.

Root `records.copy_into` now always enables native payload assignment; its public
`deepCopy` flag chooses descendant scope independently. Shallow new copies retain
fields, and shallow overwrite updates a parent without copying its child group.
Native partial creation refuses when it would unexpectedly replace a full source
with a partial shell. Native source partial/deleted semantics remain explicit in
the root API, outside the selection payload route.

Generate `selection_fixture.py generate --overlay <fresh-MO2-overlay>`, load
Fallout4.esm + AutomationSelectionScene.esm + AutomationSelectionWhole.esp +
AutomationSelectionGroup.esp + AutomationSelectionNested.esp +
AutomationSelectionShallow.esp, then run `exercise` with overlay/exe/PID/artifacts.
Relaunch fresh and run `verify`. It checks full file/group payloads and identities,
nested child-only copies with owner closure, parent/child link values, shallow
parent payload/overwrite with retained edited child, overlap/file-removal/input
refusal, recursive group removal, top-level creation/idempotence/empty-group
no-op, unchanged source/disk before save and live plus independent persisted
identity/EditorID/masters readback. Also run competing explicit/implicit owner
versions, owner-only additional dependencies, existing protected owners, other
game definitions, deleted/partial/internal/skipped records, capacity/consent
refusals, overwrite relocation, and injected partial failures. Delphi/native
execution remains pending; source fixtures are support checks only.

## Issue #35: isolated ITM/UDR jobs

Start `jobs.start` with `kind:cleaning.remove_itm` or
`kind:cleaning.undelete_and_disable_refs` and `target.files` (1..8 loaded plugins,
<=1000 total records). `dryRun` defaults true. Duplicate targets, unknown options,
TES3 and translation mode reject; apply preflights every writable target before
any file changes. One target file advances per `jobs.get`; cancel between files.
There is no master sorting/cleanup or plugin save inside either selector.

Both operations use shared native eligibility. ITM retains header flag changes,
injected masters and equal parents with nonempty child groups; partial-form
conversion is excluded. UDR refuses deleted NAVM, injected/missing base records
and FNV LOD TREE cases. It shares the native mutation with combined cleaning:
undelete/initially-disable and native session Z, XESP, scale and MSTT settings,
which each file result reports. Results contain root identities, plans, skips,
completed writes, failure locator and mutation audit. Partial writes remain in
memory with no rollback; explicitly save changed files, flush and relaunch.

Generate `selective_cleaning_fixture.py generate --overlay <fresh-MO2-overlay>`;
load Fallout4.esm + AutomationReportBase.esm + AutomationSelectiveITM.esp +
AutomationSelectiveUDR.esp + AutomationReport'Clean.esp. Run `exercise` with
`--overlay`, `--exe`, `--pid`, `--artifacts`; relaunch fresh and run `verify`.
It independently checks ITM-only versus UDR-only effects, flag-only retention,
child parent/reference retention, deleted NAVM refusal, dry-run parity, repeat
no-op, invalid/protected later targets, duplicate/shape refusal, two-file dry-run aggregation, cancellation after one apply,
native Z/XESP/scale readback,
unchanged master lists, explicit persistence and raw saved flags. Also run
TES4/Skyrim/FO3/FNV/FO76/Starfield supported definitions, native setting variants,
partial forms, injected/missing bases, FNV LOD TREE and injected partial-write
failures. Before the consent-enabled exercise, a separate daemon started without
`-IKnowWhatImDoing` can run `no-consent` with the same fixture to check both
apply refusals and allowed dry-runs. Delphi/native execution is pending.

## Issue #34: BOSS/LOOT cleaning reports

`reports.cleaning` takes `format:loot|boss`, 1..8 `files`, and optional existing
absolute `outputDirectory` with `overwrite:false` and `dryRun:true` defaults.
It scans <=1000 records in clean saved/flushed loaded source files (<=64 MiB
per source), requires clean saved masters, and retains source deny-write handles
while verifying disk CRC against the loaded snapshot. Restart after saving or
external file replacement. Counts and concrete root locators classify native
removable ITM, editable cleanable UDR, and manual deleted NAVM; skipped identities
are separate. Equal parents with nonempty child groups are retained. Master
classification uses clean loaded snapshots; master disk files are not rehashed.
It shares cleaning eligibility and the header-safe ITM comparison.
Native formatters supply quoting, tool version, LOOT clean/quickClean/reqManualFix
text and classic Oblivion BOSS text. TES3 rejects; BOSS additionally requires
`gmTES4`. GUI historical cleaning entries are excluded.

The plugin scan is read-only. Optional apply writes immediate atomic UTF-8 text
without BOM to `xedit-cleaning-loot.yaml` or `xedit-cleaning-boss.txt`, requires
consent and does not save plugins. Output failures retain the previous final file
and report temporary-file cleanup state. LOOT output is a native metadata fragment
using standard aliases, not a standalone alias-free YAML document.

Run `report_fixture.py generate --game fo4 --overlay <fresh-MO2-overlay>` and load
Fallout4.esm + AutomationReportBase.esm + AutomationReportDirty.esp +
AutomationReportQuick.esp + AutomationReport'Clean.esp in that order. Run
`exercise --game fo4 --overlay ... --output <fresh-existing-output-dir> --exe ...
--pid ... --artifacts ...`; relaunch fresh and run `verify` with a new PID. It
asserts concrete counts/identities, disk CRC, preserved flag-only override,
manual/quick/clean formatting, exact UTF-8 output, overwrite refusal/replacement,
unchanged dirty state and refusal after deliberate source editing/saving. Repeat
with `--game tes4` and Oblivion.esm to test the BOSS path. Also test dirty masters,
external source replacement, absent consent, unsupported games, limits, Unicode
names/paths and unwritable/racing outputs. Delphi/native acceptance is pending.

## Issue #33: automatic VWD from resources

`records.set_vwd_from_mesh` takes `files` (1..8 loaded plugins, <=1000 total
records) and optional `targetFile`. `dryRun` defaults true. The native Oblivion
predicate includes TES4/TES4R; other games and translation mode reject. Plans
select at most 128 exterior REFRs whose flag is clear and whose NAME base record
has a native distant-mesh resource. In-place edits require writable owned records.
Target mode chooses the latest selected version per FormID, skips native source
errors, preflights every copy/master dependency and copies an override before
setting VWD. Target must load after every eligible source; existing target
overrides refuse. Source selection does not silently expand to global winners.

Results contain eligibility, reasons, plans, completed target locators/copy
outcomes and mutation audit. Apply remains in memory until explicit plugin save
and terminal flush. Native partial failures retain earlier copies/flags without
rollback. Resource existence is cached per base record: prepare the VFS resources
before launch/first scan. This tests existence; it does not certify mesh geometry.

Generate `vwd_fixture.py generate --overlay <dedicated-MO2-overlay>` for classic
Oblivion. Load Oblivion.esm + AutomationVWDScene.esp + AutomationVWDOutput.esp.
Run `exercise` with overlay/exe/PID/artifact inputs; relaunch and run `verify`.
The fixture checks exterior eligibility, missing resources, interior/already-VWD
skips, target-only copy, repeated target refusal, in-place edits, explicit saves,
and independently decoded persisted REFR flags. Fresh-process live readback also
checks the output override identity, VWD flag, required Scene master and resolved
NAME link. Also test TES4R, TREE billboards,
multiple selected overrides, persistent world cells, protected/earlier targets,
missing masters, corrupt links, resource cache behavior, capacity gates and
partial copy failures. Delphi/native execution remains pending.

## Issue #32: ModGroups

`modgroups.list` returns native items/validation, canonical `configFile`, `name`,
SHA-256 `fileHash` and selection knowledge. Optional `configFile` scopes the
inventory (including `fileHash:"absent"` for a new discoverable sidecar).
`modgroups.activate` takes `groups:[{configFile,name}]` and optional
`enabled:true`. Empty groups deactivate. Activation changes session conflict
relationships and invalidates conflict/query caches; it never edits plugins or
persists selection. Duplicate names in different files are distinct identities.

`modgroups.write` takes `configFile`, `name`, `operation:create|update|delete`,
`expectedFileHash`, default `dryRun:true`, and `items` for create/update. Optional
`newName` renames; `allowInvalid:true` can intentionally persist a group that
native load-order/CRC/required/source predicates reject. Names and native flag/
CRC lines are bounded and INI injection/malformed input rejects. Untargeted
sections/comments are retained. Writes target only the native global config or
loaded-module .modgroups sidecars in existing directories, so native reload can
discover them. Config persistence is immediate per-file atomic replacement and
independent of plugin save. Hash validation is optimistic, not an OS compare-and-
swap; use exclusive external-editor ownership during changes.

Call activate with explicit identities before apply/reload: native UI selection
cannot be inferred safely. `modgroups.reload` and successful config writes resolve
fresh pointers and restore still-valid identities, returning dropped groups.
GUI selection/reload/toggle invalidates automation selection knowledge. If reload
fails after persistence, the response retains `written:true` and partial failure.

`modgroups.refresh_crc` takes the same identity/hash/dry-run inputs and explicit
`files` item names. `addMissing` and `appendCurrent` default true; only those
items append native loaded-module CRC history. Forbidden items skip, unsaved/
missing modules reject, and existing histories remain. Rerun from a fresh process
after plugin saving to ensure native CRC caching reflects intended disk state.
Limits: 128 groups/sections, 64 items, 32 selections, 16 CRCs/item, 1 MiB config.

Generate `modgroups_fixture.py generate --overlay <dedicated-MO2-overlay>`, load
Fallout4.esm + AutomationGroupBase.esm + AutomationGroupLeft.esp +
AutomationGroupRight.esp and run `exercise` with overlay/exe/PID/artifact inputs.
The native discoverable config must map to that overlay through MO2. It checks
create/plan/hash refusal, conflict participant removal/restoration, scoped CRC
history, rename/delete and section preservation without dirtying plugins.
Relaunch fresh and run `verify` for persisted config and actual conflict behavior.
Also test duplicate names/files, missing/optional/forbidden items, both ignore-
order modes, CRC mismatches, invalid input, external races/write failures and
game-specific module rules. Delphi/native execution remains pending.

## Issue #31: localization

`localization.tables` lists all three native resource types for `file` and the
active language. `localization.get/set` require `file`, `type` (STRINGS,
DLSTRINGS, ILSTRINGS), and an eight-digit hex `id`. Set edits an existing nonzero
ID, requires exact `expectedValue`, preserves whitespace and affects every
field sharing that ID. Primary encoding roundtrip, NUL and byte limits reject
before editing. Plugin protection/edit/consent predicates apply to table edits.

`localization.language` reads the current language or selects a resource-language
name with `language`; changes clear/reload resources and reject dirty tables or
plugins. Missing tables remain missing (native field checks diagnose unresolved
IDs); a failed resource reload requires restart. This is session state.

`localization.convert` takes `file`, `mode:localize|delocalize`, default
`dryRun:true`, and optional `reuseDuplicates:false`. Native Skyrim/FO4/FO76/SF
definitions are supported. Every field/encoding is checked before applying;
limits are 1000 fields, 100000 traversal nodes, depth 64 and 4 MiB combined text.
Unresolved IDs, literal STRINGID: text and text equal to its raw ID reject.
GUI translation-vocabulary substitution is excluded. Header flag setters remain
low-level flag edits; they do not convert string representation.

Conversion rewrites fields and changes the localized header last. After any apply
attempt, only persistence/diagnostics are permitted until terminal flush/restart.
Partial native failures have no rollback. `localization.save` atomically writes
each present binary table to explicit existing `outputDirectory`, and clears its
Modified state only after that file succeeds. Outputs must be projected into
runtime Strings for reload. `overwrite` defaults false. Preflight all tables;
later output failures retain earlier completed files. This is independent of
`session.save` for plugin data. `session.get_dirty_state` includes table dirtiness;
`session.flush` refuses unsaved tables by default. `localization.export_text` uses
the same directory/overwrite inputs and writes UTF-8 native ID/text dumps without
clearing table dirtiness. String tables are bounded to 64 MiB; each encoded value
to 1 MiB. Saving rejects fallback-decoded text that cannot roundtrip through the
primary encoding, including unchanged rows.

Generate `localization_fixture.py generate --overlay <dedicated-MO2-overlay>`.
Load Fallout4.esm + AutomationLocalization.esp with English and run `delocalize`
with `--overlay`, `--exe`, `--pid`, `--artifacts`. Relaunch fresh and run
`relocalize`; relaunch again and run `verify`. The runner checks exact long,
whitespace, empty and multilingual text; shared IDs and dirty-language refusal;
UTF-8 text export; conversion planning; edit restriction; table/plugin saves;
and independent raw table/record bytes plus fresh-process resolved values.

Before acceptance compile LiteDebug and run the above through MO2. Also test
actual INFO ILSTRINGS fields, Skyrim/FO76/SF definitions, unsupported games,
protected plugins, missing IDs/resources, language changes with different text,
malformed resources, code-page sidecars/fallbacks, capacity/ID exhaustion and
injected partial conversion/output failures. Delphi/native execution is pending.

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

## Issue #14: retained validation steps (contract 0.56)

`validation.check_for_errors`, `validation.check_for_itm` and
`validation.check_for_deleted_refs` retain a preorder traversal cursor within a
file. Each `jobs.get` performs at most 128 traversal actions, checking a soft
20ms budget between native calls. Native initialization, element checks and ITM
comparisons remain indivisible; a slow native call can exceed that budget.
Element traversal depth is capped at 64. No full child list is built or subtree rescanned.
Circular validation also uses retained steps; its graph limits and fixture are
described under issue #20 below.
`system.capabilities.supports.jobs.stepping` derives its kinds from the registry.

`progress.completed` counts fully traversed target files; `progress.detail`
reports the current/last file, visited elements, checked records, retained depth,
step count and last work count. Detail depth describes the last traversal step;
`cursorRetained` becomes false when terminal cleanup releases the cursor. Per-file result rows have `complete:false` while
partially traversed. Summary counts accumulate once across polls. A no-findings
informational result is emitted only after an entire file finishes.
`findingsComplete` is true only for succeeded jobs, including findings pages.
Cancellation/failure preserves partial rows and admitted findings. The durable
finding sink admits each finding before retaining it, with limits of 5000 entries
and 1MiB of compact UTF-8 JSON. A capacity failure keeps earlier findings and marks
the job failed, never successful. Message previews over 4096 characters report
`messageTruncated` and `originalMessageCharacters`; locator paths are retained.

Read-only probes and `jobs.findings` work between steps. Loaded graph mutations,
save, flush and scripts return `job_busy` while a job is active. Apply jobs
preflight every target's writability before mutation. Cancellation, failure,
success and discard release the retained traversal interfaces; terminal JSON
results remain available. Reentrant polling/discard is refused during a native
step, and reentrant cancellation waits until that step returns.

Compile LiteDebug using the maintainer's licensed Delphi setup, then generate a
fresh MO2 overlay and launch a fresh FO4 daemon with the two generated plugins:

```powershell
python Tools/AutomationRegression/validation_step_fixture.py generate --overlay <new-MO2-mod-folder>
python Tools/AutomationRegression/validation_step_fixture.py exercise --exe <trusted-exe> --pid <daemon-pid> --artifacts <new-capture-folder>
```

The 3200-record fixture alternates identical overrides and header-only changes.
The runner requires within-file yields for all three validation kinds, cancels
with retained ITM findings, checks read-only access and write blocking, restarts
to completion and compares the full ITM identity set without duplicates. It
checks complete rows, counters, paging and unchanged dirty state. The deleted
reference pass checks the no-findings completion path, not positive deleted
reference classification. Error-check findings must preserve their prefix across
cancel/restart; dedicated malformed-record classification remains native work.
`validation-steps.json` records every poll duration including client process/IPC
time; it does not assert a hard native latency bound.

In a separate fresh overlay/process, repeat both commands with `--capacity`.
This creates 6000 identical overrides. The runner requires a durable
`job_capacity` failure with earlier findings and an incomplete file row.
Never overwrite the first fixture or mix these variants in one loaded session.
Run `job_fixture.py --exe <exe> --pid <pid> --artifacts <folder> --files
<plugin-one> <plugin-two>` for cross-file aggregation and cancellation, using two
disposable loaded plugins.

Python integrity/runner tests pass independently of xEdit. Delphi compilation
and the above game-backed phases have **not** run locally. Issue #14 remains
open: cleaning, compaction, reference construction, reachability
and LOD still contain larger native units, and no hard latency guarantee is made.

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

## Issue #20 / #14: retained circular leveled-list validation

`validation.circular_leveled_lists` scans winning LVLI/LVLC/LVLN/LVSP roots
with the same native entry-path, same-signature and winning-override selection
helpers as the GUI checker. Automation retains its own graph stack, active-path
index and visited winning FormIDs, without reading/writing shared native tags or
resetting every loaded file. Active-path detection precedes the visited check,
matching the native cycle detector. A detected cycle aborts that root while
keeping its visited set for subsequent roots, as a native cycle exception does.
Each target file starts a new visited set, preserving the prior automation scope.
TES3 is rejected. Other games still require native acceptance testing.

The root scan, graph walk, cycle diagnostic construction and stack unwind all
yield between at most 128 actions and soft 20ms checkpoints. Native data
initialization and lookup calls remain indivisible. Retained graph depth is
limited to 1024 frames and visited winning records to 100000 per target file;
exceeding either fails with `job_capacity`, retaining previous findings and an
incomplete file row. These are explicit capacity refusals, not successful
truncated scans. `progress.detail` reports phase, checked roots, visited records,
traversed entries and last traversal depth. `cursorRetained` is false after
terminal cleanup. Summary counts include only admitted cycles and completed
files. Canceled/failed findings remain incomplete.

Findings retain the checked root's winning locator even when a cycle starts
deeper in that graph. `cyclePathNames` and new `cyclePath` locator arrays are
ordered from the cycle's first record through its repeated closing record.
Paths are capped at 100 entries, names at 160 characters and message previews at
4096 characters. `cyclePathLength`, `cyclePathTruncated`, `messageTruncated` and
`originalMessageCharacters` make truncation explicit. No partial cycle finding
is published while a diagnostic is still being built. The retained finding sink
also applies the 5000-entry/1MiB compact UTF-8 JSON budget.

Build LiteDebug with licensed Delphi, generate into a fresh MO2 overlay, and load
all three generated files in a fresh FO4 daemon, with the winner after its master:

```powershell
python Tools/AutomationRegression/circular_step_fixture.py generate --overlay <new-MO2-mod-folder>
python Tools/AutomationRegression/circular_step_fixture.py exercise --exe <trusted-exe> --pid <daemon-pid> --artifacts <new-capture-folder>
```

The fixture includes three short signature cycles, a 513-record acyclic chain,
a 400-record long cycle and master/override cases. The runner requires a deep
within-file yield with earlier findings, cancels without advancing the graph,
checks read-only access and write blocking, then restarts to completion. It
checks exact root/path identities, no acyclic false positive, bounded long-cycle
previews, stable finding prefixes, aggregation, cursor release and dirty state.
Later winning overrides must break one master cycle and preserve another, whose
root/path locators identify the actual winning owner files. `circular-steps.json`
records poll durations including client startup and IPC, without claiming a
hard native latency guarantee.

In a separate fresh overlay/process, repeat both commands with
`--depth-capacity`. The 1100-record chain must fail at the explicit depth budget,
retain its earlier cycle findings and leave the file incomplete. Repeat the
smaller original `circular_fixture.py generate/exercise` runner (with its required
`--overlay`, `--exe`, `--pid`, `--artifacts` arguments) as a compatibility check.
Test LVLC and the Oblivion direct-entry path in supported older-game profiles,
multiple target files, the visited-record limit, and the TES3 refusal separately.
The GUI recursive checker remains synchronous; verify its findings after the
shared helper extraction and verify that automation does not alter GUI tags.

Python fixture-integrity and assertion tests pass independently of xEdit.
Delphi compilation and these game-backed phases have **not** run locally. Issue
#14 still has larger native units in cleaning, compaction, reference construction,
reachability and LOD; no issue is closed based on these source-only checks.

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


### Explicit comparisons (#38)

`comparisons.records` takes 2..8 owned root locators in exact column order,
including different records from one file; native definitions must match.
Optional common `path` selects one scope, including a missing cell. Default
scope excludes record headers and child groups. Native alignment emits independent
present/visible/ignored flags and exact leaf values; leaf sibling conflict labels
are separate from override-chain status. Limits: 2048 source visits/depth16,
256 output rows/depth8 and 1MiB response. Truncation reports `complete:false`.

`comparisons.load` defaults to dry run. Supply `sourceFile`, absolute `inputPath`
and a new simple `.esp` `fileName`; explicit `dryRun:false` requires session consent.
Captured bytes are loaded with native CompareTo in memory without a disk copy.
Full nonlocalized plugins only, optional ESM header flag only, <=64MiB/1000 actual
records; all ordinary full dependencies must already be loaded before baseline.
Encoding sidecars and extended header subrecords reject; at most four comparisons.
Loaded records are read-only, participate in native override/injection chains,
and last until restart. Native load failures report unknown partial graph state;
restart before retry. Plugin save/flush cannot persist the comparison.

Generate a fresh `row_fixture.py` MO2 overlay and load Fallout4.esm plus its three
plugins. Copy AutomationRowSource.esm to an external test directory, then run
`comparison_fixture.py --overlay <overlay> --input-path <external-copy.esm>
--exe <canonical-built-tool> --pid <broker-pid> --artifacts <artifact-dir>`.
It checks ordered/reversed same-file columns, exact whitespace, missing TNAM,
row truncation, incompatible/duplicate roots, dry-run, read-only loaded copy,
mutation rejection and unchanged source bytes/revision. Native acceptance also
requires hidden/ignored/partial rows, sorted KWDA alignment/links, all capacity
limits, dependency/name/encoding/mode failures, comparison save refusal, Data
file inventory unchanged and before/after override conflict participants.
Delphi compilation and native execution remain pending.
