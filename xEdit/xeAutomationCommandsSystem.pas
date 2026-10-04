{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsSystem;

interface

implementation

uses
  SysUtils,
  TypInfo,
  JsonDataObjects,
  wbInterface,
  xeAutomationCommandsBatch,
  xeAutomationCommandsComparisons,
  xeAutomationCommandsCleaning,
  xeAutomationCommandsSelectiveCleaning,
  xeAutomationCommandsElements,
  xeAutomationCommandsExports,
  xeAutomationCommandsFileHygiene,
  xeAutomationCommandsFiles,
  xeAutomationCommandsFormIds,
  xeAutomationCommandsPatches,
  xeAutomationCommandsJobs,
  xeAutomationCommandsLOD,
  xeAutomationCommandsReachability,
  xeAutomationCommandsLocalization,
  xeAutomationCommandsModGroups,
  xeAutomationCommandsVWD,
  xeAutomationCommandsReports,
  xeAutomationCommandsSelections,
  xeAutomationCommandsPluginAnalysis,
  xeAutomationCommandsValidation,
  xeAutomationCommandsRecords,
  xeAutomationCommandsScripts,
  xeAutomationCommandsSession,
  xeAutomationCommandsSessionNavigation,
  xeAutomationErrors,
  xeAutomationJobs,
  xeAutomationObjectModel,
  xeAutomationProjection,
  xeAutomationReplay,
  xeAutomationWireLimits,
  xeAutomationRegistry;

const
  xeAutomationFinalJobKinds: array[0..16] of string = (
    'files.hygiene.batch',
    'plugin.esl.analyze',
    'plugin.esl.apply',
    'plugin.formids.compact_for_esl',
    'validation.check_for_errors',
    'validation.check_for_itm',
    'validation.check_for_deleted_refs',
    'validation.circular_leveled_lists',
    'cleaning.remove_itm',
    'cleaning.undelete_and_disable_refs',
    'cleaning.quick_clean',
    'cleaning.quick_auto_clean',
    'cleaning.sort_and_clean_masters',
    'cleaning.cleanup_injected_references',
    'analysis.reachability',
    'analysis.build_references',
    'lod.generate'
  );

procedure xeAutomationEnsureCapabilityCommandSurface;
var
  lJobKind: string;
  lPluginAnalyzeRegistered: Boolean;
  lValidationErrorsRegistered: Boolean;
  lValidationItmRegistered: Boolean;
  lValidationDeletedRefsRegistered: Boolean;
  lValidationCircularRegistered: Boolean;
  lCleaningQuickRegistered: Boolean;
  lCleaningQuickAutoRegistered: Boolean;
  lCleaningMastersRegistered: Boolean;
  lLODRegistered: Boolean;
  lReachabilityRegistered: Boolean;
begin
  // Capabilities advertises the full protocol surface even for one-shot probes;
  // register groups lazily here so the registry remains the single source of names.
  if not xeAutomationHasCommand('session.get_dirty_state') then
    xeAutomationRegisterSessionCommands;
  if not xeAutomationHasCommand('session.navigate_to_record') then
    xeAutomationRegisterSessionNavigationCommands;
  if not xeAutomationHasCommand('files.list') then
    xeAutomationRegisterFilesCommands;
  if not xeAutomationHasCommand('files.get_header') then
    xeAutomationRegisterFileHygieneCommands;
  // Capability probes are allowed before daemon serve registration; load the
  // accepted ESL/compact job group here so the complete job surface is present.
  lPluginAnalyzeRegistered := False;
  lValidationErrorsRegistered := False;
  lValidationItmRegistered := False;
  lValidationDeletedRefsRegistered := False;
  lValidationCircularRegistered := False;
  lCleaningQuickRegistered := False;
  lCleaningQuickAutoRegistered := False;
  lCleaningMastersRegistered := False;
  lLODRegistered := False;
  lReachabilityRegistered := False;
  for lJobKind in xeAutomationListJobKinds do
    if SameText(lJobKind, 'plugin.esl.analyze') then begin
      lPluginAnalyzeRegistered := True;
    end else if SameText(lJobKind, 'validation.check_for_errors') then begin
      lValidationErrorsRegistered := True;
    end else if SameText(lJobKind, 'validation.check_for_itm') then begin
      lValidationItmRegistered := True;
    end else if SameText(lJobKind, 'validation.check_for_deleted_refs') then begin
      lValidationDeletedRefsRegistered := True;
    end else if SameText(lJobKind, 'validation.circular_leveled_lists') then begin
      lValidationCircularRegistered := True;
    end else if SameText(lJobKind, 'cleaning.quick_clean') then begin
      lCleaningQuickRegistered := True;
    end else if SameText(lJobKind, 'cleaning.quick_auto_clean') then begin
      lCleaningQuickAutoRegistered := True;
    end else if SameText(lJobKind, 'cleaning.sort_and_clean_masters') then begin
      lCleaningMastersRegistered := True;
    end else if SameText(lJobKind, 'analysis.reachability') then begin
      lReachabilityRegistered := True;
    end else if SameText(lJobKind, 'lod.generate') then begin
      lLODRegistered := True;
    end;
  if not lPluginAnalyzeRegistered then
    xeAutomationRegisterPluginAnalysisCommands;
  // Keep validation capability advertising registry-derived: these kinds are
  // registered lazily only after their implementation unit is linked here.
  if not (lValidationErrorsRegistered and lValidationItmRegistered and
          lValidationDeletedRefsRegistered and lValidationCircularRegistered) then
    xeAutomationRegisterValidationCommands;
  // Cleaning capability advertising remains truthful because these kinds are
  // registered only after the 6D in-memory/apply-safe implementation is linked.
  if not (lCleaningQuickRegistered and lCleaningQuickAutoRegistered and lCleaningMastersRegistered) then
    xeAutomationRegisterCleaningCommands;
  if not lLODRegistered then xeAutomationRegisterLODJobs;
  if not lReachabilityRegistered then xeAutomationRegisterReachabilityJobs;
  if not xeAutomationHasCommand('jobs.start') then
    xeAutomationRegisterJobsCommands;
  if not xeAutomationHasCommand('records.list') then
    xeAutomationRegisterRecordsCommands;
  if not xeAutomationHasCommand('elements.get') then
    xeAutomationRegisterElementsCommands;
  if not xeAutomationHasCommand('comparisons.records') then
    xeAutomationRegisterComparisonCommands;
  if not xeAutomationHasCommand('batch.read') then
    xeAutomationRegisterBatchCommands;
  if not xeAutomationHasCommand('formids.remap') then
    xeAutomationRegisterFormIdCommands;
  if not xeAutomationHasCommand('patches.delta') then
    xeAutomationRegisterPatchCommands;
  if not xeAutomationHasCommand('exports.seq') then
    xeAutomationRegisterExportCommands;
  if not xeAutomationHasCommand('localization.tables') then
    xeAutomationRegisterLocalizationCommands;
  if not xeAutomationHasCommand('modgroups.list') then
    xeAutomationRegisterModGroupCommands;
  if not xeAutomationHasCommand('records.set_vwd_from_mesh') then
    xeAutomationRegisterVWDCommands;
  if not xeAutomationHasCommand('reports.cleaning') then
    xeAutomationRegisterReportCommands;
  if not xeAutomationHasCommand('selections.inspect') then
    xeAutomationRegisterSelectionCommands;
  // One-shot capabilities probes do not pass through serve-loop startup, so the
  // public scripts.* names are registered here before the registry is listed.
  if not xeAutomationHasCommand('scripts.list') then
    xeAutomationRegisterScriptsCommands;
end;

function xeAutomationSystemPing(const aArgs: TJsonObject): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.S['status'] := 'ok';
end;

function xeAutomationSystemDescribe(const aArgs: TJsonObject): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.S['appName'] := wbAppName;
  Result.S['gameName'] := wbGameName;
  Result.S['gameMode'] := GetEnumName(TypeInfo(TwbGameMode), Ord(wbGameMode));
  Result.S['subMode'] := wbSubMode;
  Result.S['dataPath'] := wbDataPath;
end;

procedure xeAutomationSchemaShapeField(const AShape: TJsonObject; const AName, AType: string;
  const ARequired: Boolean);
begin
  AShape.O['properties'].O[AName].S['type'] := AType;
  if ARequired then
    AShape.A['required'].Add(AName);
end;

procedure xeAutomationSchemaField(const ATarget: TJsonObject; const AName, AType: string;
  const ARequired: Boolean);
begin
  xeAutomationSchemaShapeField(ATarget.O['argumentSchema'], AName, AType, ARequired);
end;

procedure xeAutomationSchemaLocator(const ATarget: TJsonObject);
begin
  xeAutomationSchemaField(ATarget, 'file', 'string', True);
  xeAutomationSchemaField(ATarget, 'formId', 'string:8-hex-digits', True);
  xeAutomationSchemaField(ATarget, 'path', 'string:record-relative-indexed-path', False);
end;

procedure xeAutomationSchemaEffects(const ATarget: TJsonObject; const APrerequisites, APersistence: string);
begin
  ATarget.S['prerequisites'] := APrerequisites;
  ATarget.S['persistence'] := APersistence;
end;

function xeAutomationDescribeExtendedCommand(const ACommand: string; const ATarget: TJsonObject): Boolean;
const
  FilterBooleans: array[0..14] of string = ('isMaster', 'isWinningOverride', 'isDeleted', 'isInjected',
    'notReachable', 'referencesInjected', 'isPersistent', 'isVisibleWhenDistant', 'hasVWDMesh',
    'hasPrecombinedMesh', 'scaledActor', 'persistentPositionChanged', 'unnecessaryPersistent', 'masterIsTemporary', 'includeMasters');
  FilterPatterns: array[0..9] of string = ('editorIdPattern', 'displayNamePattern', 'fullNamePattern',
    'baseEditorIdPattern', 'baseDisplayNamePattern', 'editorIdRegex', 'displayNameRegex', 'fullNameRegex',
    'baseEditorIdRegex', 'baseDisplayNameRegex');
  FilterLiterals: array[0..4] of string = ('editorIdContains', 'displayNameContains', 'baseEditorIdContains',
    'baseDisplayNameContains', 'elementValueContains');
var
  lField: string;
  lValues: TJsonObject;
begin
  Result := True;
  if SameText(ACommand, 'files.list') or SameText(ACommand, 'session.options') or
     SameText(ACommand, 'session.game_link') or SameText(ACommand, 'analysis.reference_status') or
     SameText(ACommand, 'records.filter_options') or SameText(ACommand, 'records.replacement_options') or
     SameText(ACommand, 'system.diagnostics') then begin
    xeAutomationSchemaEffects(ATarget, 'Loaded session; discovery does not require consent', 'read-only native state/discovery');
    if SameText(ACommand, 'session.game_link') then
      ATarget.S['constraintNotes'] := 'Watcher control is intentionally excluded; sending mode fails with unsupported_game_link_control';
  end else if SameText(ACommand, 'system.run_diagnostic') then begin
    xeAutomationSchemaField(ATarget, 'name', 'string:system.diagnostics.diagnostics.name', True);
    xeAutomationSchemaEffects(ATarget, 'Known catalog entry; specialized diagnostics intentionally excluded in every game/build', 'no execution; no mutation');
    ATarget.A['errors'].Add('unsupported_diagnostic');
  end else if SameText(ACommand, 'files.get') or SameText(ACommand, 'files.get_header') or
              SameText(ACommand, 'files.get_masters') then begin
    if SameText(ACommand, 'files.get') then
      xeAutomationSchemaField(ATarget, 'name', 'string:loaded-plugin', True)
    else xeAutomationSchemaField(ATarget, 'file', 'string:loaded-plugin', True);
    xeAutomationSchemaEffects(ATarget, 'Loaded plugin; no consent needed', 'read-only');
  end else if SameText(ACommand, 'files.create') then begin
    xeAutomationSchemaField(ATarget, 'fileName', 'string:new-simple-plugin-basename', True);
    xeAutomationSchemaField(ATarget, 'template', 'string:empty-default-empty', False);
    xeAutomationSchemaField(ATarget, 'flags', 'object', False);
    with ATarget.O['argumentSchema'].O['properties'].O['flags'].A['allowedBooleanKeys'] do begin
      Add('esm'); Add('esl'); Add('small'); Add('medium'); Add('localized');
    end;
    xeAutomationSchemaField(ATarget, 'initialMasters', 'array<string:earlier-loaded-plugin>', False);
    xeAutomationSchemaEffects(ATarget, 'Consent/edit mode; unused basename in Data; native extension/slot/game restrictions; small/esl aliases must agree', 'new loaded plugin in memory; explicit session.save and terminal session.flush required');
    ATarget.A['errors'].Add('mutation_not_allowed');
    ATarget.A['errors'].Add('unsupported_game_mode');
  end else if SameText(ACommand, 'files.add_masters') or SameText(ACommand, 'files.add_required_masters') then begin
    xeAutomationSchemaField(ATarget, 'targetFile', 'string:loaded-writable-plugin', True);
    if SameText(ACommand, 'files.add_masters') then begin
      xeAutomationSchemaField(ATarget, 'masters', 'array<string:earlier-loaded-plugin>:1..32', True);
      xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    end else xeAutomationSchemaField(ATarget, 'source', 'object:file,formId,path:loaded-element', True);
    xeAutomationSchemaEffects(ATarget, 'Native dependency/ownership/load-order/slot gates; consent for apply; add_required_masters has no dry run', 'master edits in memory; explicit save and terminal flush');
    ATarget.A['errors'].Add('mutation_not_allowed');
  end else if SameText(ACommand, 'files.sort_masters') or SameText(ACommand, 'files.clean_masters') then begin
    xeAutomationSchemaField(ATarget, 'file', 'string:loaded-writable-plugin', True);
    xeAutomationSchemaEffects(ATarget, 'Loaded writable plugin and consent; native master sort/unused-master rules', 'in-memory-until-session.save-then-terminal-session.flush');
    ATarget.A['errors'].Add('mutation_not_allowed');
  end else if SameText(ACommand, 'files.mark_without_onam') then begin
    xeAutomationSchemaField(ATarget, 'files', 'array<string:loaded-plugin>:1..32', True);
    xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(ATarget, 'expectedRevision', 'string:decimal-uint64', False);
    xeAutomationSchemaEffects(ATarget, 'Translation mode off; writable selected files; native HasONAM gate; consent for apply', 'marks selected headers in memory; explicit save/flush');
    ATarget.A['errors'].Add('stale_revision');
  end else if SameText(ACommand, 'session.save') then begin
    xeAutomationSchemaField(ATarget, 'all', 'boolean:must-be-true-if-present', False);
    xeAutomationSchemaField(ATarget, 'files', 'array<string:loaded-plugin>:nonempty', False);
    ATarget.S['constraintNotes'] := 'Exactly one of all:true or files is required; multiple files may partially save';
    xeAutomationSchemaEffects(ATarget, 'Mutation consent; all targets resolve before first save; no competing active job', 'native plugin persistence; mapped replacement may remain pending until terminal session.flush; localization tables save separately');
    ATarget.O['example'].S['command'] := ACommand;
    ATarget.O['example'].O['args'].A['files'].Add('MyPatch.esp');
    ATarget.A['errors'].Add('save_failed');
  end else if SameText(ACommand, 'session.flush') then begin
    xeAutomationSchemaField(ATarget, 'force', 'boolean:default-false', False);
    xeAutomationSchemaEffects(ATarget, 'Consent; no active job; save plugins/tables first; force explicitly accepts loss of unsaved state', 'terminal session shutdown and pending plugin replacement; no automatic save');
    ATarget.A['errors'].Add('state_conflict');
  end else if SameText(ACommand, 'session.navigate_to_record') then begin
    xeAutomationSchemaLocator(ATarget);
    xeAutomationSchemaEffects(ATarget, 'Loaded record root; empty path; main form present and no GUI blockers', 'GUI selection/navigation only; no plugin mutation');
    ATarget.A['errors'].Add('state_conflict');
  end else if SameText(ACommand, 'session.set_options') then begin
    xeAutomationSchemaField(ATarget, 'values', 'object', True);
    lValues := ATarget.O['argumentSchema'].O['properties'].O['values'];
    lValues.A['required'].Clear; lValues.O['properties'].Clear;
    lValues.B['additionalProperties'] := False;
    lValues.I['minProperties'] := 1; lValues.I['maxProperties'] := 8;
    xeAutomationSchemaShapeField(lValues, 'alwaysSaveOnam', 'boolean', False);
    xeAutomationSchemaShapeField(lValues, 'udrSetXESP', 'boolean', False);
    xeAutomationSchemaShapeField(lValues, 'udrSetScale', 'boolean', False);
    xeAutomationSchemaShapeField(lValues, 'udrSetZ', 'boolean', False);
    xeAutomationSchemaShapeField(lValues, 'udrSetMSTT', 'boolean', False);
    xeAutomationSchemaShapeField(lValues, 'udrScaleValue', 'number:finite', False);
    lValues.O['properties'].O['udrScaleValue'].F['minimum'] := 0;
    lValues.O['properties'].O['udrScaleValue'].F['maximum'] := 10;
    xeAutomationSchemaShapeField(lValues, 'udrZValue', 'number:finite', False);
    lValues.O['properties'].O['udrZValue'].F['minimum'] := -10000000;
    lValues.O['properties'].O['udrZValue'].F['maximum'] := 10000000;
    xeAutomationSchemaField(ATarget, 'expectedSessionRevision', 'string:decimal-uint64', False);
    xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    ATarget.S['constraintNotes'] := 'Unknown/startup keys reject; MSTT requires native wbIsFallout3; forced ONAM cannot disable; numeric values must be finite';
    xeAutomationSchemaEffects(ATarget, 'Inspect session.options; complete typed preflight; consent for apply; no active job', 'session-only semantic options/revision; no settings or plugin disk write');
    ATarget.A['errors'].Add('stale_session_revision');
    ATarget.A['errors'].Add('unsupported_option');
  end else if SameText(ACommand, 'localization.tables') or SameText(ACommand, 'localization.get') or
              SameText(ACommand, 'localization.set') then begin
    xeAutomationSchemaField(ATarget, 'file', 'string:loaded-localized-plugin', True);
    if not SameText(ACommand, 'localization.tables') then begin
      xeAutomationSchemaField(ATarget, 'type', 'string:strings|dlstrings|ilstrings', True);
      xeAutomationSchemaField(ATarget, 'id', 'string:8-hex-digit-string-id', True);
    end;
    if SameText(ACommand, 'localization.set') then begin
      xeAutomationSchemaField(ATarget, 'value', 'string:exact-full-text', True);
      xeAutomationSchemaField(ATarget, 'expectedValue', 'string:exact-current-text', True);
      xeAutomationSchemaEffects(ATarget, 'Supported localization game; writable plugin/table, existing nonzero ID, exact old value and consent', 'localized table in memory; localization.save writes tables; plugin save is separate');
      ATarget.A['errors'].Add('state_conflict');
    end else xeAutomationSchemaEffects(ATarget, 'Supported localization game and resolved loaded string tables; no consent needed', 'read-only table access');
    ATarget.A['errors'].Add('unsupported_game_mode');
  end else if SameText(ACommand, 'localization.language') then begin
    xeAutomationSchemaField(ATarget, 'language', 'string:native-supported-language', False);
    xeAutomationSchemaEffects(ATarget, 'Read without language; changing requires consent, clean plugins and clean tables; restart after failed reload', 'session language and resource-cache reload only; no plugin/table/settings disk save');
    ATarget.A['errors'].Add('state_conflict');
  end else if SameText(ACommand, 'localization.convert') then begin
    xeAutomationSchemaField(ATarget, 'file', 'string:loaded-writable-nonzero-load-order-plugin', True);
    xeAutomationSchemaField(ATarget, 'mode', 'string:localize|delocalize', True);
    xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(ATarget, 'reuseDuplicates', 'boolean:default-false', False);
    xeAutomationSchemaEffects(ATarget, 'Supported localization game, resolved native string reads, bounded complete field/table preflight; consent for apply', 'plugin/table representation changes in memory; explicit plugin/table saves and terminal flush; restart required after apply');
    ATarget.A['errors'].Add('localization_capacity');
    ATarget.A['errors'].Add('unsupported_game_mode');
  end else if SameText(ACommand, 'localization.save') or SameText(ACommand, 'localization.export_text') then begin
    xeAutomationSchemaField(ATarget, 'file', 'string:loaded-plugin', True);
    xeAutomationSchemaField(ATarget, 'outputDirectory', 'string:absolute-existing-directory', True);
    xeAutomationSchemaField(ATarget, 'overwrite', 'boolean:default-false', False);
    xeAutomationSchemaEffects(ATarget, 'Supported localization game and consent; native table snapshot/encoding preflight; save also needs writable plugin', 'immediate external table/text files; per-file atomic write; earlier outputs retained on later failure; no plugin save');
    ATarget.S['constraintNotes'] := 'No dry run; project saved tables into runtime Strings for reload';
    ATarget.A['errors'].Add('external_output_failed');
  end else if SameText(ACommand, 'modgroups.list') then begin
    xeAutomationSchemaField(ATarget, 'configFile', 'string:absolute-approved-modgroups-config-path', False);
    xeAutomationSchemaEffects(ATarget, 'Loaded native ModGroups; optional config path must meet native path policy', 'read-only config/selection inventory and hashes');
  end else if SameText(ACommand, 'modgroups.activate') then begin
    xeAutomationSchemaField(ATarget, 'groups', 'array<object:configFile,name>:0..32', True);
    xeAutomationSchemaField(ATarget, 'enabled', 'boolean:default-true', False);
    xeAutomationSchemaEffects(ATarget, 'Consent; explicit valid nonduplicate native groups and main form; empty array removes group relationships', 'session-only conflict/group selection; invalidates derived queries; no config/plugin save');
  end else if SameText(ACommand, 'modgroups.reload') then begin
    xeAutomationSchemaEffects(ATarget, 'Consent; known automation-owned selection; native reload resolves the same identities', 'reload native config and reapply session selection; no config/plugin write');
    ATarget.A['errors'].Add('state_conflict');
  end else if SameText(ACommand, 'modgroups.write') or SameText(ACommand, 'modgroups.refresh_crc') then begin
    xeAutomationSchemaField(ATarget, 'configFile', 'string:absolute-approved-modgroups-config-path', True);
    xeAutomationSchemaField(ATarget, 'name', 'string:native-group-section-name', True);
    xeAutomationSchemaField(ATarget, 'expectedFileHash', 'string:modgroups.list.fileHash', True);
    xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(ATarget, 'allowInvalid', 'boolean:default-false', False);
    if SameText(ACommand, 'modgroups.write') then begin
      xeAutomationSchemaField(ATarget, 'operation', 'string:create|update|delete', True);
      xeAutomationSchemaField(ATarget, 'newName', 'string:native-group-section-name', False);
      xeAutomationSchemaField(ATarget, 'items', 'array<string:native-plugin-flags-and-optional-crc-line>:2..64', False);
      ATarget.S['constraintNotes'] := 'items required for create/update; delete omits replacement lines; newName applies only to nondelete operations';
    end else begin
      xeAutomationSchemaField(ATarget, 'addMissing', 'boolean:default-true', False);
      xeAutomationSchemaField(ATarget, 'appendCurrent', 'boolean:default-true', False);
      ATarget.S['constraintNotes'] := 'Refresh requires existing group; adds missing CRCs/appends current CRC according to explicit booleans';
    end;
    xeAutomationSchemaEffects(ATarget, 'Exact current config hash, known selection, bounded native candidate validation; consent for apply', 'immediate external config write/reload; session selection refreshed; plugins unchanged');
    ATarget.A['errors'].Add('state_conflict');
    ATarget.A['errors'].Add('modgroup_capacity');
  end else if SameText(ACommand, 'messages.read') or SameText(ACommand, 'messages.export') then begin
    if SameText(ACommand, 'messages.read') then begin
      xeAutomationSchemaField(ATarget, 'cursor', 'string:session-snapshot-message-cursor', False);
      xeAutomationSchemaField(ATarget, 'limit', 'integer:1..200-default-100', False);
      xeAutomationSchemaEffects(ATarget, 'Retained session messages; expired/evicted snapshots require restart from earliest available', 'read-only bounded retained message window');
      ATarget.A['errors'].Add('message_cursor_invalid'); ATarget.A['errors'].Add('message_cursor_expired');
    end else begin
      xeAutomationSchemaField(ATarget, 'outputDirectory', 'string:absolute-existing-directory', True);
      xeAutomationSchemaField(ATarget, 'fileName', 'string:plain-txt-basename-default-xedit-messages.txt', False);
      xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
      xeAutomationSchemaField(ATarget, 'overwrite', 'boolean:default-false', False);
      xeAutomationSchemaEffects(ATarget, 'Explicit output root/name and retained window; consent for apply', 'immediate external UTF8 text on apply; plugins unchanged; eviction/truncation explicit');
    end;
  end else if SameText(ACommand, 'logs.analyze') then begin
    xeAutomationSchemaField(ATarget, 'format', 'string:papyrus|xse-profiler', True);
    xeAutomationSchemaField(ATarget, 'inputDirectory', 'string:absolute-existing-directory', True);
    xeAutomationSchemaField(ATarget, 'fileName', 'string:plain-log-or-txt-basename-max80', True);
    xeAutomationSchemaField(ATarget, 'encoding', 'string:utf-8|native-ansi-default-utf-8', False);
    xeAutomationSchemaEffects(ATarget, 'Papyrus requires Skyrim family; xSE profiler requires TES4/FO3/FNV; captured losslessly decoded input <=256KiB', 'read-only bounded native attribution; explicit incompleteness; no plugin/log write');
    ATarget.A['errors'].Add('unsupported_game_mode'); ATarget.A['errors'].Add('log_capacity');
  end else if SameText(ACommand, 'scripts.list') or SameText(ACommand, 'scripts.read') or
              SameText(ACommand, 'scripts.write') or SameText(ACommand, 'scripts.delete') or
              SameText(ACommand, 'scripts.run') then begin
    if SameText(ACommand, 'scripts.list') then begin
      xeAutomationSchemaField(ATarget, 'prefix', 'string:script-id-prefix', False);
      xeAutomationSchemaField(ATarget, 'limit', 'integer:nonnegative-native-clamped-list-limit', False);
    end else xeAutomationSchemaField(ATarget, 'id', 'string:canonical-script-id', True);
    if SameText(ACommand, 'scripts.write') then begin
      xeAutomationSchemaField(ATarget, 'source', 'string:exact-script-source', True);
      xeAutomationSchemaField(ATarget, 'overwrite', 'boolean:default-false', False);
    end;
    if SameText(ACommand, 'scripts.run') then begin
      xeAutomationSchemaField(ATarget, 'targets', 'array<object:file,formId,path>:optional-native-target-scope', False);
      xeAutomationSchemaField(ATarget, 'acceptKnownBlockers', 'boolean:default-false', False);
      xeAutomationSchemaField(ATarget, 'timeoutMs', 'integer:0..4294967295-native-soft-budget', False);
      xeAutomationSchemaField(ATarget, 'maxStatements', 'integer:0..4294967295-native-soft-budget', False);
      xeAutomationSchemaEffects(ATarget, 'Consent, canonical stored script, lint/policy admission and exclusive script execution guard; native budget checks are cooperative', 'script-dependent plugin memory and possible external effects; plugin persistence requires explicit save/flush; exceptions may retain earlier changes');
      ATarget.A['errors'].Add('script_busy');
    end else if SameText(ACommand, 'scripts.write') or SameText(ACommand, 'scripts.delete') then
      xeAutomationSchemaEffects(ATarget, 'Consent; canonical allowed agent-script storage path; write overwrite admission', 'immediate script file write/delete; plugins unchanged')
    else xeAutomationSchemaEffects(ATarget, 'Canonical native script storage policy; no consent needed', 'read-only script inventory/source');
  end else if SameText(ACommand, 'records.base_record') or SameText(ACommand, 'records.master_or_self') or
              SameText(ACommand, 'records.winning_override') or SameText(ACommand, 'records.conflict_status') then begin
    xeAutomationSchemaLocator(ATarget);
    if SameText(ACommand, 'records.conflict_status') then
      xeAutomationSchemaField(ATarget, 'limit', 'integer:positive-native-clamped-default-100', False)
    else if not SameText(ACommand, 'records.base_record') then
      xeAutomationSchemaField(ATarget, 'includeParents', 'boolean:default-false', False);
    xeAutomationSchemaEffects(ATarget, 'Loaded record; base/conflict endpoints require empty root path; no consent needed', 'read-only native record/relationship/conflict access; derived conflict caches may initialize');
  end else if SameText(ACommand, 'records.find_by_form_id') or SameText(ACommand, 'records.find_by_editor_id') then begin
    xeAutomationSchemaField(ATarget, 'includeParents', 'boolean:default-false', False);
    if SameText(ACommand, 'records.find_by_form_id') then begin
      xeAutomationSchemaField(ATarget, 'formId', 'string:8-hex-load-order-formId', True);
      xeAutomationSchemaField(ATarget, 'file', 'string:optional-loaded-plugin-scope', False);
    end else begin
      xeAutomationSchemaField(ATarget, 'editorId', 'string:native-editor-id', True);
      xeAutomationSchemaField(ATarget, 'signature', 'string:optional-record-signature', False);
    end;
    xeAutomationSchemaEffects(ATarget, 'Loaded plugin graph; no consent needed; editor-ID search is bounded', 'read-only identity search; inspect truncated before claiming complete results');
  end else if SameText(ACommand, 'records.list') or SameText(ACommand, 'records.apply_filter') or
              SameText(ACommand, 'records.references') or SameText(ACommand, 'records.referenced_by') then begin
    xeAutomationSchemaField(ATarget, 'cursor', 'string:single-use-session-query-continuation', False);
    xeAutomationSchemaField(ATarget, 'offset', 'integer:nonnegative-default-0', False);
    if SameText(ACommand, 'records.apply_filter') then begin
      xeAutomationSchemaField(ATarget, 'limit', 'integer:1..100-default-100', False);
      xeAutomationSchemaField(ATarget, 'files', 'array<string:explicit-loaded-plugin-scope>', True);
      xeAutomationSchemaField(ATarget, 'signatures', 'array<string:record-signature>', False);
      xeAutomationSchemaField(ATarget, 'baseSignatures', 'array<string:base-record-signature>', False);
      xeAutomationSchemaField(ATarget, 'parentFormId', 'string:8-hex-formId', False);
      xeAutomationSchemaField(ATarget, 'baseFormId', 'string:8-hex-formId', False);
      xeAutomationSchemaField(ATarget, 'conflictAll', 'array<string:native-conflictAll-name>', False);
      xeAutomationSchemaField(ATarget, 'conflictThis', 'array<string:native-conflictThis-name>', False);
      xeAutomationSchemaField(ATarget, 'preset', 'string:conflicts', False);
      for lField in FilterBooleans do xeAutomationSchemaField(ATarget, lField, 'boolean:presence-selects-true-or-false', False);
      for lField in FilterPatterns do xeAutomationSchemaField(ATarget, lField, 'string-or-array<string>:glob-or-bounded-regex', False);
      for lField in FilterLiterals do xeAutomationSchemaField(ATarget, lField, 'string:case-insensitive-literal-max1024', False);
      ATarget.S['constraintNotes'] := 'AND across predicates, OR within arrays; same-field glob/regex exclusive; inspect records.filter_options for game/domain/index requirements';
    end else begin
      xeAutomationSchemaField(ATarget, 'limit', 'integer:1..500-default-100', False);
      if SameText(ACommand, 'records.list') then begin
        xeAutomationSchemaField(ATarget, 'file', 'string:loaded-plugin', True);
        xeAutomationSchemaField(ATarget, 'signature', 'string:optional-record-signature', False);
      end else begin
        xeAutomationSchemaLocator(ATarget);
        if SameText(ACommand, 'records.references') then
          xeAutomationSchemaField(ATarget, 'recursive', 'boolean:default-false-native-child-roots', False);
      end;
    end;
    xeAutomationSchemaEffects(ATarget, 'Loaded scope; reverse/injected/unnecessary-persistent predicates require current reference indexes; notReachable needs completed current global analysis', 'read-only paged query; single-use cursor bound to original arguments and mutation/semantic revisions');
    ATarget.S['resultNotes'] := 'Continue with identical original arguments plus nextCursor; consume even empty pages; inspect complete/incompleteReason; never treat timeout/budget refusal as no match';
    ATarget.A['errors'].Add('cursor_invalidated'); ATarget.A['errors'].Add('cursor_capacity');
  end else if SameText(ACommand, 'records.create') then begin
    xeAutomationSchemaField(ATarget, 'targetFile', 'string:loaded-writable-plugin', True);
    xeAutomationSchemaField(ATarget, 'signature', 'string:native-creatable-record-signature', True);
    xeAutomationSchemaField(ATarget, 'editorId', 'string:optional-supported-editor-id', False);
    xeAutomationSchemaField(ATarget, 'parent', 'object:file,formId,subGroup?:native-parent-spec', False);
    xeAutomationSchemaEffects(ATarget, 'Consent; enabled native signature; supported EditorID definition; owned/writable native parent preflight', 'native creation in memory; explicit save/flush; partial failure/rollback audit; parent groups/consumed IDs may remain');
    ATarget.S['constraintNotes'] := 'Parent required by native child-record signature; inspect parent/group recipes; no caller-specified FormID allocation';
  end else if SameText(ACommand, 'records.delete') or SameText(ACommand, 'records.mark_deleted') then begin
    xeAutomationSchemaLocator(ATarget);
    if SameText(ACommand, 'records.mark_deleted') then
      xeAutomationSchemaField(ATarget, 'expectedDeleted', 'boolean:optional-current-deleted-state', False);
    xeAutomationSchemaEffects(ATarget, 'Owned writable record root and consent; root path must be empty', 'in-memory-until-session.save-then-terminal-session.flush');
    ATarget.S['constraintNotes'] := 'delete physically removes root and owned child group; mark_deleted sets Deleted=true only; expectedDeleted mismatch refuses before setting';
    ATarget.A['errors'].Add('state_conflict');
  end else if SameText(ACommand, 'records.mark_modified') or SameText(ACommand, 'records.set_reference_flags') then begin
    xeAutomationSchemaField(ATarget, 'records', 'array<object:file,formId>:1..32-owned-roots', True);
    xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(ATarget, 'expectedRevision', 'string:decimal-uint64', False);
    if SameText(ACommand, 'records.set_reference_flags') then begin
      xeAutomationSchemaField(ATarget, 'persistent', 'boolean:desired-native-flag', False);
      xeAutomationSchemaField(ATarget, 'visibleWhenDistant', 'boolean:desired-native-flag', False);
      ATarget.S['constraintNotes'] := 'At least one desired flag required; only REFR; each locator may include expectedPersistent/expectedVisibleWhenDistant; existing owned complete CELL destinations only';
    end else ATarget.S['constraintNotes'] := 'Nonoverlapping roots; complete native descendant preflight <=50000 nodes/depth32; includes owned child groups';
    xeAutomationSchemaEffects(ATarget, 'Translation off; all native writable/ownership/placement predicates checked before apply; consent for apply', 'native flags or recursive serialization markers in memory; explicit save/flush; actual changed/dirty/generation outcomes returned');
    ATarget.A['errors'].Add('stale_revision'); ATarget.A['errors'].Add('mutation_not_allowed');
  end else if SameText(ACommand, 'records.set_vwd_from_mesh') then begin
    xeAutomationSchemaField(ATarget, 'files', 'array<string:loaded-plugin>:1..8', True);
    xeAutomationSchemaField(ATarget, 'targetFile', 'string:optional-writable-override-destination', False);
    xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaEffects(ATarget, 'Oblivion only; translation off; native resource containers and eligible exterior REFR winners; consent for apply', 'native VWD edits/optional target overrides in memory; explicit save and terminal flush');
    ATarget.A['errors'].Add('unsupported_game_mode');
  end else if SameText(ACommand, 'records.replace') then begin
    xeAutomationSchemaField(ATarget, 'source', 'object:file,formId:owned-full-record-root', True);
    xeAutomationSchemaField(ATarget, 'target', 'object:file,formId:owned-writable-record-root', True);
    xeAutomationSchemaField(ATarget, 'expectedRevision', 'string:decimal-uint64', True);
    xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(ATarget, 'addRequiredMasters', 'boolean:default-false', False);
    xeAutomationSchemaEffects(ATarget, 'Numeric nonlocalized matching full native roots; inspect records.replacement_options exclusions; bounded full payload/master preflight; consent for apply', 'native Assign in memory; target identity retained; complete before/source/after readback; partial failure audit; explicit save/flush');
    ATarget.A['errors'].Add('stale_revision'); ATarget.A['errors'].Add('unsupported_game_mode');
  end else Result := False;
end;

procedure xeAutomationDescribeJobKindSchema(const AKind: string; const ATarget: TJsonObject);
var
  lTarget, lOptions, lSettings: TJsonObject;
begin
  lTarget := ATarget.O['argumentSchema'].O['properties'].O['target'];
  lOptions := ATarget.O['argumentSchema'].O['properties'].O['options'];
  lTarget.S['type'] := 'object'; lTarget.A['required'].Clear; lTarget.O['properties'].Clear;
  lOptions.S['type'] := 'object'; lOptions.A['required'].Clear; lOptions.O['properties'].Clear;
  ATarget.S['jobKind'] := AKind;
  ATarget.B['jobSchemaAvailable'] := True;
  ATarget.O['argumentSchema'].O['properties'].O['kind'].A['enum'].Add(AKind);
  xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:default-true', False);
  if SameText(AKind, 'lod.generate') then begin
    xeAutomationSchemaField(ATarget, 'options', 'object', True);
    xeAutomationSchemaShapeField(lTarget, 'worldspaces', 'array<object:file,formId>:1..4-WRLD-roots', True);
    xeAutomationSchemaShapeField(lOptions, 'outputRoot', 'string:absolute-existing-output-directory-max160', True);
    xeAutomationSchemaShapeField(lOptions, 'operation', 'string:generate|splitAtlas-default-generate', False);
    xeAutomationSchemaShapeField(lOptions, 'objects', 'boolean:game-and-operation-default', False);
    xeAutomationSchemaShapeField(lOptions, 'trees', 'boolean:game-and-operation-default', False);
    xeAutomationSchemaShapeField(lOptions, 'settings', 'object', False);
    lSettings := lOptions.O['properties'].O['settings'];
    lSettings.O['properties'].Clear; lSettings.A['required'].Clear;
    xeAutomationSchemaShapeField(lSettings, 'atlasWidth', 'integer:power-of-two-1024..8192-game-default', False);
    xeAutomationSchemaShapeField(lSettings, 'atlasHeight', 'integer:power-of-two-1024..8192-game-default', False);
    xeAutomationSchemaShapeField(lSettings, 'textureSize', 'integer:256|512|1024-default-512', False);
    xeAutomationSchemaShapeField(lSettings, 'brightness', 'integer:-30..30-default-0', False);
    xeAutomationSchemaShapeField(lSettings, 'alphaThreshold', 'integer:0..255-default-128', False);
    xeAutomationSchemaShapeField(lSettings, 'trees3D', 'boolean:default-false-Skyrim-object-LOD-only', False);
    xeAutomationSchemaShapeField(lSettings, 'noTangents', 'boolean:default-false', False);
    xeAutomationSchemaShapeField(lSettings, 'noVertexColors', 'boolean:Fallout3-default-true-otherwise-false', False);
    xeAutomationSchemaShapeField(lSettings, 'lodLevel', 'integer:4|8|16', False);
    xeAutomationSchemaShapeField(lSettings, 'x', 'integer:-32768..32767', False);
    xeAutomationSchemaShapeField(lSettings, 'y', 'integer:-32768..32767', False);
    ATarget.S['constraintNotes'] := 'TES4/Skyrim/FO3/FNV/FO4; no FO76/SF; tree/split only Skyrim/FO3/FNV; split cannot combine object/tree flags; SSE/VR/EnderalSE objects require LODGen startup. x/y require each other and lodLevel. FO3 native forces textureSize=1024,noTangents=false,noVertexColors=true';
    xeAutomationSchemaEffects(ATarget, 'Native resource containers, bounded owned complete WRLDs, existing output root; consent for apply; inspect LOD capability limits', 'immediate external per-worldspace LOD outputs; cancellation retains completed output; plugins unchanged');
  end else if SameText(AKind, 'analysis.build_references') then begin
    xeAutomationSchemaShapeField(lTarget, 'files', 'array<string:loaded-plugin>:1..32', False);
    xeAutomationSchemaShapeField(lTarget, 'allLoaded', 'boolean:default-false-true-selects-full-loaded-graph', False);
    ATarget.S['constraintNotes'] := 'Choose allLoaded:true without files, or explicit nonempty files; target.steps is reserved; no active parallel native reference build; 256 loaded-file plan limit';
    xeAutomationSchemaEffects(ATarget, 'Numeric plugin definitions; loaded selected scope; apply rebuilds stale indexes without plugin mutation', 'derived reference index memory; cache writes suppressed; no plugin save');
  end else if SameText(AKind, 'analysis.reachability') then begin
    xeAutomationSchemaShapeField(lTarget, 'files', 'array<string:report-scope-plugin>:1..32', True);
    xeAutomationSchemaShapeField(lTarget, 'roots', 'array<object:file,formId>:0..32-additional-roots', False);
    ATarget.S['constraintNotes'] := 'Non-TES3; whole loaded graph analyzed; files limits report only; target.steps reserved; <=1000 reported records, <=256 loaded files, <=1000000 loaded records';
    xeAutomationSchemaEffects(ATarget, 'Loaded global graph and resolved optional root records; only succeeded current snapshots are valid', 'derived global reachability flags in memory; plugins unchanged; cancel/failure invalidates classification');
  end else if SameText(AKind, 'cleaning.cleanup_injected_references') then begin
    xeAutomationSchemaShapeField(lTarget, 'files', 'array<string:source-file>:1..32', True);
    xeAutomationSchemaField(ATarget, 'options', 'object', True);
    xeAutomationSchemaShapeField(lOptions, 'records', 'array<object:file,formId>:1..128-explicit-roots', True);
    xeAutomationSchemaShapeField(lOptions, 'injectionFile', 'string:optional-expected-native-injection-provider', False);
    xeAutomationSchemaShapeField(lOptions, 'overwrite', 'boolean:default-false', False);
    xeAutomationSchemaShapeField(lOptions, 'addRequiredMasters', 'boolean:default-true', False);
    ATarget.S['constraintNotes'] := 'Non-TES3, translation off; same full native injection provider; explicit records belong to target.files; preserve original payload by copying before native RemoveInjected';
    xeAutomationSchemaEffects(ATarget, 'Owned full source roots/native injection provider; complete dependency/ownership preflight; consent for apply', 'preservation copies and injected-link cleanup in memory; inspect partial/manual-review results; explicit save/flush');
  end else begin
    xeAutomationSchemaShapeField(lTarget, 'files', 'array<string:loaded-plugin>:nonempty', True);
    if SameText(AKind, 'files.hygiene.batch') then begin
      xeAutomationSchemaField(ATarget, 'options', 'object', True);
      xeAutomationSchemaShapeField(lOptions, 'operations', 'array<string:sort_masters|clean_masters>:nonempty', True);
      xeAutomationSchemaEffects(ATarget, 'Complete loaded writable file scope; consent for apply', 'native master hygiene in memory; explicit save/flush; prior file outcomes retained on failure/cancel');
    end else if SameText(AKind, 'cleaning.remove_itm') or SameText(AKind, 'cleaning.undelete_and_disable_refs') then begin
      xeAutomationSchemaShapeField(lTarget, 'files', 'array<string:loaded-plugin>:1..8', False);
      lTarget.B['additionalProperties'] := False;
      lOptions.B['additionalProperties'] := False;
      ATarget.S['constraintNotes'] := 'Empty/omitted options; <=1000 selected records; non-TES3, translation off; no master hygiene; retained classification before apply, <=128 actions/16 mutation calls and soft 20ms per poll; native calls indivisible; UDR settings rechecked; immutable finding events, partial rows on cancel/failure';
      xeAutomationSchemaEffects(ATarget, 'Bounded full source records and writable targets; consent for apply; retained child-group/NAVM rules', 'isolated ITM or UDR plugin edits in memory; explicit save/flush');
    end else if SameText(AKind, 'plugin.esl.analyze') then begin
      xeAutomationSchemaEffects(ATarget, 'Native ESL/light-slot game predicates; loaded selected files', 'read-only native eligibility analysis; plugins unchanged');
    end else if SameText(AKind, 'plugin.esl.apply') or SameText(AKind, 'plugin.formids.compact_for_esl') then begin
      if SameText(AKind, 'plugin.esl.apply') then
        xeAutomationSchemaShapeField(lOptions, 'allowAfterCompact', 'boolean:default-false', False);
      xeAutomationSchemaEffects(ATarget, 'Native ESL/light-slot eligibility and writable targets; apply requires consent; compaction/referrer safety gates', 'native ESL flag/optional FormID compaction in memory; remaps/partial outcomes reported; explicit save/flush');
    end else if SameText(AKind, 'validation.check_for_errors') or SameText(AKind, 'validation.check_for_itm') or
                SameText(AKind, 'validation.check_for_deleted_refs') or SameText(AKind, 'validation.circular_leveled_lists') then begin
      xeAutomationSchemaField(ATarget, 'dryRun', 'boolean:always-normalized-true', False);
      xeAutomationSchemaEffects(ATarget, 'Loaded scope and native check predicates; circular leveled-list check excludes TES3; no mutation consent needed', 'validation only; findings/derived native traversal state; plugins unchanged');
      if not SameText(AKind, 'validation.circular_leveled_lists') then
        ATarget.S['constraintNotes'] := 'Retained within-file traversal; <=128 traversal actions and soft 20ms checkpoint per poll, depth <=64; native calls indivisible; findings <=5000/1MiB; canceled/failed findings incomplete'
      else
        ATarget.S['constraintNotes'] := 'Retained root/graph/report/unwind steps; <=128 actions and soft 20ms checkpoint per poll; graph depth <=1024, visited winning records <=100000 per file; same-signature winning edges, LVLI/LVLC/LVLN/LVSP roots; no shared native tags; native calls indivisible; partial canceled/failed findings';
    end else if SameText(AKind, 'cleaning.quick_clean') or SameText(AKind, 'cleaning.quick_auto_clean') or
                SameText(AKind, 'cleaning.sort_and_clean_masters') then begin
      xeAutomationSchemaEffects(ATarget, 'Writable selected files and native game/cleaning predicates; consent for apply', 'retained full-file native cleaning/master hygiene in memory; explicit save/flush; partial operations retained on cancel/failure');
      ATarget.S['constraintNotes'] := 'Preorder collection before each ITM/UDR phase; full-file scope without selective record/depth caps; <=128 actions and <=16 native mutations per poll, soft 20ms checkpoints; native calls indivisible; sort and clean masters in separate polls; aggregate stage findings';
    end else begin
      ATarget.B['jobSchemaAvailable'] := False;
      ATarget.S['constraintNotes'] := 'Registered future kind has no authored target/options descriptor yet';
    end;
  end;
end;

function xeAutomationSystemCommandSchema(const AArgs: TJsonObject): TJsonObject;
var
  lCommand, lKind, lRegisteredKind, lField: string;
  lExample, lExampleItem: TJsonObject;
  i: Integer;
  lExampleComplete, lKnownKind: Boolean;
begin
  lCommand := LowerCase(xeAutomationRequireStringArg(AArgs, 'command'));
  xeAutomationEnsureCapabilityCommandSurface;
  if not xeAutomationHasCommand(lCommand) then
    raise xeAutomationUnknownCommand(lCommand);
  lKind := '';
  if AArgs.Contains('kind') then begin
    if lCommand <> 'jobs.start' then
      raise xeAutomationInvalidRequest('Schema kind is only supported for jobs.start');
    lKind := LowerCase(xeAutomationRequireStringArg(AArgs, 'kind'));
    lKnownKind := False;
    for lRegisteredKind in xeAutomationListJobKinds do
      lKnownKind := lKnownKind or (lRegisteredKind = lKind);
    if not lKnownKind then
      raise xeAutomationNewError(xeAutomationErrorUnknownJobKind, 'Schema job kind is not registered: ' + lKind);
  end;
  Result := TJsonObject.Create;
  Result.S['command'] := lCommand;
  Result.B['schemaAvailable'] := True;
  Result.O['argumentSchema'].S['type'] := 'object';
  Result.O['argumentSchema'].A['required'].Clear;
  Result.O['argumentSchema'].O['properties'].Clear;
  Result.A['errors'].Add('invalid_request');
  if SameText(lCommand, 'system.command_schema') then begin
    xeAutomationSchemaField(Result, 'command', 'string:registered-command', True);
    xeAutomationSchemaField(Result, 'kind', 'string:registered-job-kind-only-for-jobs.start', False);
    Result.S['prerequisites'] := 'None; unimplemented schemas return schemaAvailable:false';
    Result.S['persistence'] := 'read-only';
    Result.O['example'].S['command'] := lCommand;
    Result.O['example'].O['args'].S['command'] := 'elements.set_value';
  end else if SameText(lCommand, 'elements.set_value') or
     SameText(lCommand, 'elements.set_native_value') then begin
    xeAutomationSchemaLocator(Result);
    if SameText(lCommand, 'elements.set_value') then
      xeAutomationSchemaField(Result, 'value', 'string', True)
    else
      xeAutomationSchemaField(Result, 'value', 'json-scalar-or-formId-array', True);
    xeAutomationSchemaField(Result, 'expectedRevision', 'string:decimal-uint64', False);
    xeAutomationSchemaField(Result, 'expectedValue', 'string:exact-edit-value', False);
    if SameText(lCommand, 'elements.set_native_value') then begin
      xeAutomationSchemaField(Result, 'kind', 'string', False);
      with Result.O['argumentSchema'].O['properties'].O['kind'].A['enum'] do begin
        Add('int'); Add('float'); Add('string'); Add('bool'); Add('formId'); Add('formIdArray');
      end;
    end;
    Result.S['prerequisites'] :=
      'Loaded owned editable element and mutation consent; inspect elements.edit_capabilities and elements.get_value first';
    Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
    Result.A['errors'].Add('stale_revision');
    Result.A['errors'].Add('stale_value');
    Result.A['errors'].Add('mutation_not_allowed');
    lExample := Result.O['example'];
    lExample.S['command'] := lCommand;
    lExample.O['args'].S['file'] := 'MyPatch.esp';
    lExample.O['args'].S['formId'] := '01000800';
    lExample.O['args'].S['path'] := 'EDID';
    lExample.O['args'].S['expectedRevision'] := '<session.get_dirty_state.mutationRevision>';
    lExample.O['args'].S['expectedValue'] := '<elements.get_value.values.editValue>';
    lExample.O['args'].S['value'] := 'ReplacementEditorId';
  end else if SameText(lCommand, 'elements.get') or
              SameText(lCommand, 'elements.get_value') or
              SameText(lCommand, 'elements.conflict_status') or
              SameText(lCommand, 'elements.required_masters') or
              SameText(lCommand, 'elements.assign_templates') or
              SameText(lCommand, 'elements.children') or
              SameText(lCommand, 'elements.subtree') or
              SameText(lCommand, 'records.get') then begin
    xeAutomationSchemaLocator(Result);
    if SameText(lCommand, 'elements.conflict_status') then begin
      xeAutomationSchemaField(Result, 'path', 'string:nonempty-existing-child-path', True);
      xeAutomationSchemaField(Result, 'limit', 'integer:positive-native-clamped-default-100', False);
    end;
    if SameText(lCommand, 'elements.get') or SameText(lCommand, 'elements.children') or SameText(lCommand, 'elements.subtree') or
       SameText(lCommand, 'records.get') then
      xeAutomationSchemaField(Result, 'includeParents', 'boolean:default-false', False);
    if SameText(lCommand, 'elements.assign_templates') then
      xeAutomationSchemaField(Result, 'targetIndex', 'integer:default-append', False);
    if SameText(lCommand, 'elements.children') then begin
      xeAutomationSchemaField(Result, 'offset', 'integer:nonnegative-default-0', False);
      xeAutomationSchemaField(Result, 'limit', 'integer:1..1000-default-200', False);
      Result.S['resultNotes'] := 'Immediate native children are paged; use offset until truncated=false';
    end else if SameText(lCommand, 'elements.subtree') then begin
      xeAutomationSchemaField(Result, 'maxNodes', 'integer:1..256-default-64', False);
      xeAutomationSchemaField(Result, 'maxDepth', 'integer:0..8-default-4', False);
      Result.S['resultNotes'] := 'Flat preorder nodes with depth/parentIndex/canonical locators and per-node complete; native payload plus contextual ChildGroups; no exact total or retained continuation';
      Result.S['constraintNotes'] := '1024 explicit node/slot/signature visits, <=1 MiB compact UTF-8; limits stop before whole-tree materialization; depth cuts branches and continues siblings; partial reads expose truncationReasons; native getters indivisible';
      Result.A['errors'].Add('result_too_large');
      Result.A['errors'].Add('stale_revision');
    end else if SameText(lCommand, 'elements.get_value') then
      Result.S['resultNotes'] := 'Full edit/native value with exact whitespace, bounded to 1048576 characters';
    Result.S['prerequisites'] := 'Loaded file and record; no mutation consent needed';
    Result.S['persistence'] := 'read-only';
  end else if SameText(lCommand, 'session.get_dirty_state') or
              SameText(lCommand, 'session.get_gui_snapshot') or
              SameText(lCommand, 'system.ping') or SameText(lCommand, 'system.describe') or
              SameText(lCommand, 'system.capabilities') then begin
    Result.S['prerequisites'] := 'Loaded session';
    Result.S['persistence'] := 'read-only';
    if SameText(lCommand, 'session.get_dirty_state') then
      Result.S['resultNotes'] := 'mutationRevision is the optimistic edit token';
  end else if SameText(lCommand, 'jobs.start') then begin
    xeAutomationSchemaField(Result, 'kind', 'string:system.capabilities.supports.jobs.kinds', True);
    xeAutomationSchemaField(Result, 'target', 'object:kind-specific-explicit-scope', True);
    xeAutomationSchemaField(Result, 'options', 'object:kind-specific-options', False);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:kind-specific-default', False);
    Result.S['prerequisites'] := 'Loaded session; no competing active job; apply needs mutation consent and kind-specific preflight';
    Result.S['persistence'] := 'queues native work; plugin apply remains in memory until explicit save/flush; LOD may write external output';
    Result.S['constraintNotes'] := 'Target/options are specific to the chosen kind; this schema documents the start envelope only';
    Result.A['errors'].Add('job_busy');
    Result.A['errors'].Add('mutation_not_allowed');
  end else if SameText(lCommand, 'jobs.get') or SameText(lCommand, 'jobs.findings') or
              SameText(lCommand, 'jobs.cancel') or SameText(lCommand, 'jobs.discard') then begin
    xeAutomationSchemaField(Result, 'jobId', 'string:retained-session-job-id', True);
    if SameText(lCommand, 'jobs.findings') then begin
      xeAutomationSchemaField(Result, 'offset', 'integer:nonnegative-default-0', False);
      xeAutomationSchemaField(Result, 'limit', 'integer:positive-clamped-500-default-100', False);
    end;
    Result.S['prerequisites'] := 'Retained job in this session; discard requires terminal state';
    Result.S['persistence'] := 'session-only job lifecycle; get advances native work and may mutate plugins or write external output';
    Result.S['constraintNotes'] := 'Cancellation yields between native steps; jobs.get is not a passive status probe';
    Result.O['example'].S['command'] := lCommand;
    Result.O['example'].O['args'].S['jobId'] := '<jobs.start.jobId>';
  end else if SameText(lCommand, 'elements.set_to_default') or SameText(lCommand, 'elements.clear') or
              SameText(lCommand, 'elements.remove_child') or SameText(lCommand, 'elements.move_up') or
              SameText(lCommand, 'elements.move_down') or SameText(lCommand, 'elements.next_member') or
              SameText(lCommand, 'elements.previous_member') then begin
    xeAutomationSchemaLocator(Result);
    if SameText(lCommand, 'elements.remove_child') then
      xeAutomationSchemaField(Result, 'path', 'string:nonempty-existing-child-path', True);
    xeAutomationSchemaField(Result, 'expectedRevision', 'string:decimal-uint64', False);
    xeAutomationSchemaField(Result, 'expectedValue', 'string:exact-edit-value', False);
    Result.S['prerequisites'] := 'Owned writable target, mutation consent and native operation predicate; inspect elements.edit_capabilities';
    Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
    Result.S['constraintNotes'] := 'remove_child requires a nonempty child path; structural edits can invalidate indexed paths; re-enumerate afterward';
    Result.A['errors'].Add('stale_revision');
    Result.A['errors'].Add('stale_value');
    Result.A['errors'].Add('mutation_not_allowed');
  end else if SameText(lCommand, 'elements.copy_child_to') then begin
    xeAutomationSchemaField(Result, 'source', 'object:file,formId,path:existing-child', True);
    xeAutomationSchemaField(Result, 'target', 'object:file,formId,path:owned-container', True);
    xeAutomationSchemaField(Result, 'targetIndex', 'integer:default-append', False);
    xeAutomationSchemaField(Result, 'addRequiredMasters', 'boolean:default-false', False);
    xeAutomationSchemaField(Result, 'expectedRevision', 'string:decimal-uint64', False);
    Result.S['prerequisites'] := 'Loaded source child; owned writable target, consent, native CanAssign and required masters';
    Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
    Result.S['constraintNotes'] := 'Source/target are nested locators; no expectedValue support on this command; re-enumerate after sorted assignment';
    Result.A['errors'].Add('mutation_not_allowed');
  end else if SameText(lCommand, 'elements.edit_capabilities') then begin
    xeAutomationSchemaLocator(Result);
    xeAutomationSchemaField(Result, 'targetIndex', 'integer:default-append', False);
    xeAutomationSchemaField(Result, 'source', 'object:element-locator', False);
    Result.S['prerequisites'] := 'Loaded element; no mutation consent needed';
    Result.S['persistence'] := 'read-only';
    Result.S['resultNotes'] :=
      'Reports native edit type, bounded choices, resolved reference, templates, operation predicates and mutationRevision';
  end else if SameText(lCommand, 'elements.add_child') then begin
    xeAutomationSchemaLocator(Result);
    xeAutomationSchemaField(Result, 'targetIndex', 'integer:default-append', False);
    xeAutomationSchemaField(Result, 'templateIndex', 'integer', False);
    xeAutomationSchemaField(Result, 'templateName', 'string', False);
    xeAutomationSchemaField(Result, 'expectedRevision', 'string:decimal-uint64', False);
    xeAutomationSchemaField(Result, 'expectedValue', 'string:exact-edit-value', False);
    Result.S['prerequisites'] :=
      'Owned writable container, consent and native CanAssign; inspect assign_templates/edit_capabilities for valid templates';
    Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
    Result.A['errors'].Add('stale_revision');
    Result.A['errors'].Add('stale_value');
    Result.A['errors'].Add('mutation_not_allowed');
  end else if Copy(lCommand, 1, 11) = 'selections.' then begin
    if SameText(lCommand, 'selections.create_group') then begin
      xeAutomationSchemaField(Result, 'file', 'string:loaded-plugin', True);
      xeAutomationSchemaField(Result, 'signature', 'string:enabled-native-top-level-signature', True);
    end else begin
      xeAutomationSchemaField(Result, 'selections', 'array<object:kind,file,groupPath>:1..16', True);
      if SameText(lCommand, 'selections.copy_into') then begin
        xeAutomationSchemaField(Result, 'targetFile', 'string:later-loaded-writable-plugin', True);
        xeAutomationSchemaField(Result, 'overwrite', 'boolean:default-false', False);
        xeAutomationSchemaField(Result, 'addRequiredMasters', 'boolean:default-true', False);
      end;
    end;
    if not SameText(lCommand, 'selections.inspect') then
      xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    Result.S['prerequisites'] := 'Non-TES3, translation mode off; current native groupPath type/8-hex-label from inspect; copy needs partial creation off and full nondeleted/nonpartial records; writes need consent and native writable targets';
    Result.S['persistence'] := 'inspect-read-only; edits-in-memory-until-explicit-save-and-terminal-flush; empty-groups-may-be-omitted';
    Result.S['constraintNotes'] := '128 records including implicit copy owners, 2048 retained nodes and group-path sibling visits, depth 8; duplicate/overlapping selectors and multiple source identity versions reject; file removal/unload/disk delete excluded';
    Result.A['errors'].Add('selection_capacity');
    Result.A['errors'].Add('mutation_not_allowed');
    Result.A['errors'].Add('unsupported_game_mode');
  end else if SameText(lCommand, 'reports.cleaning') then begin
    xeAutomationSchemaField(Result, 'format', 'string:loot|boss', True);
    xeAutomationSchemaField(Result, 'files', 'array<string:loaded-plugin>:1..8', True);
    xeAutomationSchemaField(Result, 'outputDirectory', 'string:absolute-existing-directory', False);
    xeAutomationSchemaField(Result, 'overwrite', 'boolean:default-false', False);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    Result.S['prerequisites'] := 'Clean saved/flushed loaded sources/masters; non-TES3, translation mode off; BOSS only gmTES4; consent for output apply';
    Result.S['persistence'] := 'read-only-plugin-scan; optional-immediate-atomic-external-UTF8-output';
    Result.S['constraintNotes'] := '<=1000 records, <=64 MiB/source; source disk CRC matches loaded snapshot; nonempty child-group parents retained; master disk files not rehashed';
    Result.O['example'].S['command'] := lCommand;
    Result.O['example'].O['args'].S['format'] := 'loot';
    Result.O['example'].O['args'].A['files'].Add('Patch.esp');
    Result.O['example'].O['args'].B['dryRun'] := True;
    Result.A['errors'].Add('state_conflict');
    Result.A['errors'].Add('report_capacity');
    Result.A['errors'].Add('unsupported_game_mode');
    Result.A['errors'].Add('external_output_failed');
  end else if SameText(lCommand, 'files.set_header_flags') then begin
    xeAutomationSchemaField(Result, 'file', 'string', True);
    xeAutomationSchemaField(Result, 'flags', 'object', True);
    with Result.O['argumentSchema'].O['properties'].O['flags'].A['allowedBooleanKeys'] do begin
      Add('esm'); Add('esl'); Add('small'); Add('medium'); Add('localized');
    end;
    Result.S['prerequisites'] :=
      'Loaded writable non-protected plugin and consent; light/medium flags depend on supported game mode';
    Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
    Result.S['constraintNotes'] := 'small and esl are aliases and must agree when both supplied';
    Result.A['errors'].Add('unsupported_game_mode');
    Result.A['errors'].Add('mutation_not_allowed');
  end else if SameText(lCommand, 'comparisons.records') then begin
    xeAutomationSchemaField(Result, 'records', 'array<object:file,formId>:2..8', True);
    xeAutomationSchemaField(Result, 'path', 'string:common-native-element-path', False);
    xeAutomationSchemaField(Result, 'rowLimit', 'integer:1..256-default-256', False);
    xeAutomationSchemaField(Result, 'depth', 'integer:0..8-default-8', False);
    Result.S['effect'] := 'read-only plugin payload; derived native alignment; explicit column order';
    Result.S['prerequisites'] := 'Compatible loaded numeric records; non-TES3, translation off; bounded owned payload paths';
    Result.S['persistence'] := 'read-only plugin payload; derived alignment only';
  end else if SameText(lCommand, 'comparisons.load') then begin
    xeAutomationSchemaField(Result, 'sourceFile', 'string:ordinary-full-loaded-baseline', True);
    xeAutomationSchemaField(Result, 'inputPath', 'string:absolute-existing-plugin', True);
    xeAutomationSchemaField(Result, 'fileName', 'string:new-simple-esp-session-name', True);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    Result.S['effect'] := 'session-only native comparison load; no disk copy; changes override graph';
    Result.S['prerequisites'] := 'Nonlocalized full numeric baseline and captured comparison; earlier loaded full dependencies; apply requires consent';
    Result.S['persistence'] := 'session-only comparison graph; restart removes comparison; no plugin or external output write';
  end else if SameText(lCommand, 'batch.rows') then begin
    xeAutomationSchemaField(Result, 'items', 'array<object:mode,target,source?>', True);
    Result.O['argumentSchema'].O['properties'].O['items'].I['minItems'] := 1;
    Result.O['argumentSchema'].O['properties'].O['items'].I['maxItems'] := 16;
    with Result.O['argumentSchema'].O['properties'].O['items'].O['itemSchema'] do begin
      S['type'] := 'object'; A['required'].Add('mode'); A['required'].Add('target');
      O['properties'].O['mode'].S['type'] := 'string';
      O['properties'].O['mode'].A['enum'].Add('replace');
      O['properties'].O['mode'].A['enum'].Add('append');
      O['properties'].O['mode'].A['enum'].Add('remove');
      O['properties'].O['target'].S['type'] := 'object:owned-child-locator:file,formId,path';
      O['properties'].O['source'].S['type'] := 'object:owned-child-locator:required-for-replace-append-forbidden-for-remove';
    end;
    xeAutomationSchemaField(Result, 'expectedRevision', 'string:decimal-uint64', True);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(Result, 'addRequiredMasters', 'boolean:default-false', False);
    Result.S['prerequisites'] := 'Non-TES3, translation off; owned full nondeleted records, writable targets; native CanAssign/IsRemovable; consent for apply';
    Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
    Result.S['constraintNotes'] := 'replace existing payload row with matching definition/type; append one entry to an existing array; remove existing child. 256KiB request, 2048 scope visits, depth16, disjoint targets, sources never target records; no missing-ancestor creation or implicit mirror deletion';
    Result.S['resultNotes'] := 'planned/applied/failed/not-attempted per item; complete may be false on partial native failure; resultLocator is transient: re-enumerate rows after the entire batch';
    Result.A['errors'].Add('stale_revision');
    Result.A['errors'].Add('unsupported_game_mode');
    Result.A['errors'].Add('mutation_not_allowed');
    Result.A['errors'].Add('state_conflict');
  end else if SameText(lCommand, 'batch.read') or SameText(lCommand, 'batch.edit') then begin
    xeAutomationSchemaField(Result, 'items', 'array<object:command,args>', True);
    if SameText(lCommand, 'batch.read') then
      Result.O['argumentSchema'].O['properties'].O['items'].I['maxItems'] := 32
    else
      Result.O['argumentSchema'].O['properties'].O['items'].I['maxItems'] := 16;
    if SameText(lCommand, 'batch.edit') then begin
      xeAutomationSchemaField(Result, 'expectedRevision', 'string:decimal-uint64', True);
      Result.S['prerequisites'] :=
        'Consent; each item is elements.set_value with expectedValue; all owned/writable targets preflight before writes';
      Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
      Result.S['constraintNotes'] := 'At most one edit per record and 256 KiB encoded request';
      Result.A['errors'].Add('stale_revision');
      Result.A['errors'].Add('stale_value');
    end else begin
      Result.S['prerequisites'] :=
        'Read allowlist: records.get, elements.get, elements.get_value, elements.children, elements.subtree';
      Result.S['persistence'] := 'read-only';
      Result.S['constraintNotes'] := 'Children need explicit limit <=50; subtree needs explicit maxNodes <=50; complete:false if any subtree is incomplete; response <=1 MiB';
    end;
  end else if SameText(lCommand, 'exports.seq') then begin
    xeAutomationSchemaField(Result, 'file', 'string:loaded-plugin', True);
    xeAutomationSchemaField(Result, 'outputPath', 'string:absolute-existing-directory-matching-plugin-basename-seq', True);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(Result, 'overwrite', 'boolean:default-false', False);
    Result.S['prerequisites'] := 'Skyrim-family game, loaded plugin; load-order-zero skips; new SGE quests or overrides enabling SGE on non-SGE masters; apply requires consent';
    Result.S['persistence'] := 'immediate atomic external SEQ output; no plugin mutation; unsaved source changes require separate plugin save';
    Result.S['constraintNotes'] := '10000 scanned quests, 1000 eligible IDs, absolute path <=240 characters; existing output folder; no eligible IDs leave existing output untouched';
    Result.S['resultNotes'] := 'Fixed file-local IDs, headerless little-endian u32 bytes, eligible locators, skip counts, written flag and temporary-file failure state';
    Result.A['errors'].Add('export_capacity');
    Result.A['errors'].Add('state_conflict');
    Result.A['errors'].Add('unsupported_game_mode');
  end else if SameText(lCommand, 'patches.merge') then begin
    xeAutomationSchemaField(Result, 'records', 'array<object:file,formId>:1..32', True);
    xeAutomationSchemaField(Result, 'targetFile', 'string:empty-loaded-plugin-last-in-load-order', True);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    Result.S['prerequisites'] := 'TES4/FO3/FNV; explicit root selection uses all loaded overrides and each declared-master baseline; empty target loads last; apply requires consent/writable target';
    Result.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush';
    Result.S['constraintNotes'] := '32 records, 128 overrides per record, 512 entries per list, 16384 inspected entries; native list families; modern games reject; faulty ordered/deleted participants skip entire record';
    Result.S['resultNotes'] := 'Per-record planned/applied/unchanged/skipped outcomes, list counts, winners, required masters and first phase/index failure; no rollback';
    Result.A['errors'].Add('patch_capacity');
    Result.A['errors'].Add('unsupported_game_mode');
    Result.A['errors'].Add('state_conflict');
    with Result.O['example'] do begin
      S['command'] := lCommand;
      O['args'].A['records'].AddObject.S['file'] := 'Source.esm';
      O['args'].A['records'].O[0].S['formId'] := '01000800';
      O['args'].S['targetFile'] := 'Merged.esp';
      O['args'].B['dryRun'] := True;
    end;
  end else if SameText(lCommand, 'patches.delta') then begin
    xeAutomationSchemaField(Result, 'sourceFile', 'string:loaded-saved-baseline', True);
    xeAutomationSchemaField(Result, 'comparePath', 'string:existing-external-plugin-path', True);
    xeAutomationSchemaField(Result, 'outputFile', 'string:new-simple-esu-filename', True);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(Result, 'markRemovedDeleted', 'boolean:default-true', False);
    xeAutomationSchemaField(Result, 'removeIdentical', 'boolean:default-true', False);
    Result.S['prerequisites'] := 'Numeric non-localized plugins; loaded comparison masters before saved baseline; new Data output name; apply requires consent/edit mode';
    Result.S['persistence'] := 'apply immediately creates an external .esu copy; native delta edits require session.save and terminal session.flush';
    Result.S['constraintNotes'] := '1000 records per input, comparison <=64 MiB; dry run is header/dependency-only; changed master mappings retain uncertain records; encoding sidecars reject';
    Result.S['resultNotes'] := 'Reports external-copy and loaded state, deletion/identical counts, retained records and phase/partial failure; no automatic rollback';
    Result.A['errors'].Add('patch_capacity');
    Result.A['errors'].Add('state_conflict');
    with Result.O['example'] do begin
      S['command'] := lCommand;
      O['args'].S['sourceFile'] := 'Baseline.esp';
      O['args'].S['comparePath'] := 'C:\\Fixtures\\NewVersion.esp';
      O['args'].S['outputFile'] := 'VersionDelta.esu';
      O['args'].B['dryRun'] := True;
    end;
  end else if SameText(lCommand, 'records.copy_into') then begin
    xeAutomationSchemaField(Result, 'source', 'object:file,formId', True);
    xeAutomationSchemaField(Result, 'target', 'object:file', True);
    xeAutomationSchemaField(Result, 'mode', 'string:override,new,wrapper,spawn_rate', True);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true-for-wrapper-spawn-only', False);
    xeAutomationSchemaField(Result, 'editorId', 'string:required-for-wrapper', False);
    xeAutomationSchemaField(Result, 'editorIdPrefix', 'string', False);
    xeAutomationSchemaField(Result, 'editorIdSuffix', 'string', False);
    xeAutomationSchemaField(Result, 'deepCopy', 'boolean:default-false', False);
    xeAutomationSchemaField(Result, 'overwrite', 'boolean:default-false', False);
    xeAutomationSchemaField(Result, 'addRequiredMasters', 'boolean:default-true', False);
    Result.S['prerequisites'] := 'Writable loaded target, native copy/dependency rules; special modes require leveled list, no existing override, supported game, deepCopy/overwrite false';
    Result.S['persistence'] := 'dry-run-plan-or-in-memory-until-session.save';
    Result.S['constraintNotes'] := 'Wrapper returns content and forwarding locators. Spawn retains originals plus nine copies each; preflights LLCT capacity';
    Result.A['errors'].Add('state_conflict');
    Result.A['errors'].Add('unsupported_game_mode');
    with Result.O['example'] do begin
      S['command'] := lCommand;
      O['args'].O['source'].S['file'] := 'Source.esm';
      O['args'].O['source'].S['formId'] := '01000800';
      O['args'].O['target'].S['file'] := 'Patch.esp';
      O['args'].S['mode'] := 'wrapper';
      O['args'].S['editorId'] := 'WrappedContent';
      O['args'].B['dryRun'] := True;
    end;
  end else if SameText(lCommand, 'records.copy_idle_tree') then begin
    xeAutomationSchemaField(Result, 'sources', 'array<object:file,formId>:1..128', True);
    xeAutomationSchemaField(Result, 'targetFile', 'string', True);
    xeAutomationSchemaField(Result, 'oldModelPrefix', 'string:resource-directory', True);
    xeAutomationSchemaField(Result, 'newModelPrefix', 'string:different-resource-directory', True);
    xeAutomationSchemaField(Result, 'editorIdPrefix', 'string:prefix-or-suffix-required', False);
    xeAutomationSchemaField(Result, 'editorIdSuffix', 'string:prefix-or-suffix-required', False);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(Result, 'addRequiredMasters', 'boolean:default-true', False);
    Result.S['prerequisites'] := 'TES4/FO3/FNV native IDLE schemas, explicit winners in one model directory, writable non-update target, complete selection/master preflight';
    Result.S['persistence'] := 'dry-run-plan-or-in-memory-until-session.save';
    Result.S['resultNotes'] := 'Returns complete winner/copy mapping and phase/index on partial failure; selected internal links remap, external links remain original';
    Result.A['errors'].Add('unsupported_game_mode');
    Result.A['errors'].Add('state_conflict');
    with Result.O['example'] do begin
      S['command'] := lCommand;
      O['args'].A['sources'].AddObject.S['file'] := 'Source.esm';
      O['args'].A['sources'].O[0].S['formId'] := '01000800';
      O['args'].S['targetFile'] := 'Patch.esp';
      O['args'].S['oldModelPrefix'] := 'characters\old';
      O['args'].S['newModelPrefix'] := 'characters\new';
      O['args'].S['editorIdPrefix'] := 'Copied';
      O['args'].B['dryRun'] := True;
    end;
  end else if SameText(lCommand, 'formids.remap') or
              SameText(lCommand, 'formids.change') or
              SameText(lCommand, 'formids.renumber') or
              SameText(lCommand, 'formids.inject') or
              SameText(lCommand, 'references.replace') then begin
    if SameText(lCommand, 'formids.remap') then
      xeAutomationSchemaField(Result, 'mappings', 'array<object:file,oldFormId,newFormId>', True)
    else if SameText(lCommand, 'references.replace') then
      xeAutomationSchemaField(Result, 'mappings', 'array<object:oldFormId,newFormId>', True);
    if SameText(lCommand, 'formids.change') then begin
      xeAutomationSchemaLocator(Result);
      xeAutomationSchemaField(Result, 'newFormId', 'string:8-hex-digits', True);
    end;
    if SameText(lCommand, 'formids.renumber') or SameText(lCommand, 'formids.inject') then begin
      xeAutomationSchemaField(Result, 'file', 'string', True);
      xeAutomationSchemaField(Result, 'formIds', 'array<string:formId>:default-all-new-records', False);
      xeAutomationSchemaField(Result, 'startFormId', 'string:8-hex-digits',
        SameText(lCommand, 'formids.renumber'));
    end;
    if SameText(lCommand, 'formids.inject') then begin
      xeAutomationSchemaField(Result, 'masterFile', 'string:earlier-loaded-master', True);
      xeAutomationSchemaField(Result, 'preserveObjectIds', 'boolean:default-true', False);
    end;
    if SameText(lCommand, 'formids.renumber') then
      xeAutomationSchemaField(Result, 'endFormId', 'string:8-hex-digits', False);
    if SameText(lCommand, 'references.replace') then
      xeAutomationSchemaField(Result, 'scopeFiles', 'array<string:loaded-file>', True);
    xeAutomationSchemaField(Result, 'dryRun', 'boolean:default-true', False);
    xeAutomationSchemaField(Result, 'addRequiredMasters', 'boolean:default-false', False);
    if Copy(lCommand, 1, 8) = 'formids.' then
      xeAutomationSchemaField(Result, 'updateRefs', 'boolean:default-true', False);
    Result.S['prerequisites'] :=
      'Loaded records and complete reference index; collisions, master order, writable overrides/referrers preflight before apply';
    Result.S['persistence'] := 'dry-run-read-or-in-memory-until-session.save-and-terminal-session.flush';
    Result.S['constraintNotes'] := 'At most 32 mappings, 1024 total referrers and 1024 overrides; overlapping ranges/swaps reject; reference chains reject; native partial failures are reported';
    Result.A['errors'].Add('formid_collision');
    Result.A['errors'].Add('reference_capacity');
    Result.A['errors'].Add('mutation_not_allowed');
  end else if not xeAutomationDescribeExtendedCommand(lCommand, Result) then begin
    Result.B['schemaAvailable'] := False;
    Result.S['reason'] := 'Detailed schema is not yet authored for this registered command';
    Result.Remove('argumentSchema');
  end;
  if (lCommand = 'jobs.start') and (lKind <> '') then
    xeAutomationDescribeJobKindSchema(lKind, Result);
  // These arguments are enforced by the host for every registered wire command.
  if Result.B['schemaAvailable'] then begin
    if not Result.O['argumentSchema'].O['properties'].Contains('expectedRevision') then
      xeAutomationSchemaField(Result, 'expectedRevision', 'string:decimal-uint64-wire-precondition', False);
    xeAutomationSchemaField(Result, 'fields', 'array<string:allowed-summary-projection-field>:0..32', False);
    Result.O['argumentSchema'].O['properties'].O['fields'].I['maxItems'] := 32;
    for lField in xeAutomationProjectionFieldNames do
      Result.O['argumentSchema'].O['properties'].O['fields'].A['itemEnum'].Add(lField);
    xeAutomationSchemaField(Result, 'includeRelations', 'boolean:default-true', False);
    Result.B['errorsExhaustive'] := False;
  end;
  if Result.B['schemaAvailable'] and not Result.Contains('example') then begin
    lExample := Result.O['example'];
    lExample.S['command'] := lCommand;
    if Result.O['argumentSchema'].O['properties'].Contains('file') then
      lExample.O['args'].S['file'] := 'MyPatch.esp';
    if Result.O['argumentSchema'].O['properties'].Contains('formId') then
      lExample.O['args'].S['formId'] := '01000800';
    if SameText(lCommand, 'files.set_header_flags') then
      lExample.O['args'].O['flags'].B['esl'] := True
    else if SameText(lCommand, 'elements.add_child') then
      lExample.O['args'].I['templateIndex'] := 0
    else if SameText(lCommand, 'batch.read') then begin
      lExampleItem := lExample.O['args'].A['items'].AddObject;
      lExampleItem.S['command'] := 'records.get';
      lExampleItem.O['args'].S['file'] := 'MyPatch.esp';
      lExampleItem.O['args'].S['formId'] := '01000800';
    end else if SameText(lCommand, 'batch.rows') then begin
      lExample.O['args'].S['expectedRevision'] := '<session.get_dirty_state.mutationRevision>';
      lExample.O['args'].B['dryRun'] := True;
      lExampleItem := lExample.O['args'].A['items'].AddObject;
      lExampleItem.S['mode'] := 'replace';
      with lExampleItem.O['source'] do begin
        S['file'] := 'Source.esm'; S['formId'] := '01000800'; S['path'] := 'DESC';
      end;
      with lExampleItem.O['target'] do begin
        S['file'] := 'MyPatch.esp'; S['formId'] := '02000800'; S['path'] := 'DESC';
      end;
    end else if SameText(lCommand, 'batch.edit') then begin
      lExample.O['args'].S['expectedRevision'] := '<session.get_dirty_state.mutationRevision>';
      lExampleItem := lExample.O['args'].A['items'].AddObject;
      lExampleItem.S['command'] := 'elements.set_value';
      with lExampleItem.O['args'] do begin
        S['file'] := 'MyPatch.esp'; S['formId'] := '01000800'; S['path'] := 'EDID';
        S['expectedValue'] := 'OldEditorId'; S['value'] := 'NewEditorId';
      end;
    end else if SameText(lCommand, 'formids.change') then begin
      lExample.O['args'].S['newFormId'] := '01000900';
      lExample.O['args'].B['dryRun'] := True;
    end else if SameText(lCommand, 'formids.renumber') then begin
      lExample.O['args'].S['startFormId'] := '01000900';
      lExample.O['args'].B['dryRun'] := True;
    end else if SameText(lCommand, 'formids.inject') then begin
      lExample.O['args'].S['masterFile'] := 'MyMaster.esm';
      lExample.O['args'].B['preserveObjectIds'] := True;
      lExample.O['args'].B['dryRun'] := True;
    end else if SameText(lCommand, 'formids.remap') or
                SameText(lCommand, 'references.replace') then begin
      lExampleItem := lExample.O['args'].A['mappings'].AddObject;
      if SameText(lCommand, 'formids.remap') then
        lExampleItem.S['file'] := 'MyPatch.esp'
      else
        lExample.O['args'].A['scopeFiles'].Add('MyPatch.esp');
      lExampleItem.S['oldFormId'] := '01000800';
      lExampleItem.S['newFormId'] := '01000900';
      lExample.O['args'].B['dryRun'] := True;
    end;
  end;
  // Never advertise a request example with missing required fields. Generic
  // locator examples cannot describe every command's nested selectors.
  lExampleComplete := Result.B['schemaAvailable'] and Result.Contains('example');
  if lExampleComplete then begin
    lExample := Result.O['example'];
    lExampleComplete := (lExample.S['command'] = lCommand) and
      (not lExample.Contains('args') or (lExample.Types['args'] = jdtObject));
    if lExampleComplete then begin
      lExampleItem := lExample.O['args'];
      for i := 0 to Pred(Result.O['argumentSchema'].A['required'].Count) do
        if not lExampleItem.Contains(Result.O['argumentSchema'].A['required'].S[i]) then
          lExampleComplete := False;
    end;
  end;
  if not lExampleComplete then
    Result.Remove('example');
  Result.B['exampleAvailable'] := lExampleComplete;
  if lExampleComplete then
    Result.S['exampleNotes'] := 'Request shape only; replace illustrative files, FormIDs, paths and angle-bracket tokens with discovered session values';
end;

procedure xeAutomationWriteSchemaCoverage(const ATarget: TJsonObject);
var
  lArgs, lSchema: TJsonObject;
  lCommand, lKind: string;
  lCovered: Integer;
begin
  lArgs := TJsonObject.Create;
  try
    lCovered := 0;
    ATarget.A['missingCommands'].Clear;
    for lCommand in xeAutomationListCommands do begin
      lArgs.S['command'] := lCommand;
      lSchema := xeAutomationSystemCommandSchema(lArgs);
      try
        if lSchema.B['schemaAvailable'] then Inc(lCovered)
        else ATarget.A['missingCommands'].Add(lCommand);
      finally lSchema.Free; end;
    end;
    ATarget.I['coveredCommands'] := lCovered;
    ATarget.I['registeredCommands'] := lCovered + ATarget.A['missingCommands'].Count;
    ATarget.B['partialCoverage'] := ATarget.A['missingCommands'].Count > 0;
    lCovered := 0;
    ATarget.A['missingJobKinds'].Clear;
    lArgs.S['command'] := 'jobs.start';
    for lKind in xeAutomationListJobKinds do begin
      lArgs.S['kind'] := lKind;
      lSchema := xeAutomationSystemCommandSchema(lArgs);
      try
        if lSchema.B['jobSchemaAvailable'] then Inc(lCovered)
        else ATarget.A['missingJobKinds'].Add(lKind);
      finally lSchema.Free; end;
    end;
    ATarget.I['coveredJobKinds'] := lCovered;
    ATarget.I['registeredJobKinds'] := lCovered + ATarget.A['missingJobKinds'].Count;
    ATarget.B['partialJobKindCoverage'] := ATarget.A['missingJobKinds'].Count > 0;
    ATarget.S['jobKindArgument'] := 'kind, when command:jobs.start';
  finally lArgs.Free; end;
end;

function xeAutomationSystemCapabilities(const aArgs: TJsonObject): TJsonObject;
var
  lCommands: TJsonArray;
  lCommandNames: TArray<string>;
  lCommandName: string;
  lJobKind: string;
  lScripts: TJsonObject;
  lChildGroupNavigation: TJsonObject;
  lElementsChildrenPagination: TJsonObject;
  lApplyFilterExtensions: TJsonObject;
  lApplyFilterRegex: TJsonObject;
  lApplyFilterMultiPattern: TJsonObject;
  lApplyFilterPagination: TJsonObject;
  lFilesCreateAliases: TJsonObject;
  lHeaderFlagAliases: TJsonObject;
  lReferencesRecursive: TJsonObject;
  lConflictStatusChildGroup: TJsonObject;
  lCreateParentSpec: TJsonObject;
  lReverseNavigation: TJsonObject;
begin
  Result := TJsonObject.Create;
  // Contract 0.28 adds explicit FormID and scoped reference mappings.
  Result.S['contractVersion'] := '0.59';
  Result.O['supports'].O['replacement'].S['commands'] := 'records.replace; records.replacement_options; batch.rows mode:replace';
  Result.O['supports'].O['replacement'].S['scope'] := 'explicit matching full owned roots; preserve target FormID, source flags/version, native VCS reset; bounded full payload readback';
  Result.O['supports'].O['replacement'].S['externalCompare'] := 'comparison-file assignment intentionally excluded; comparisons.load/records remain read-only';
  Result.O['supports'].O['replacement'].B['nativeAcceptancePending'] := True;
  with Result.O['supports'].O['comparisons'] do begin
    S['recordsCommand'] := 'comparisons.records'; S['loadCommand'] := 'comparisons.load';
    S['scope'] := 'explicit ordered columns, common payload path, native sibling leaf classification';
    S['limits'] := '2..8 columns; 2048 source visits/depth16; 256 rows/depth8; 1MiB response; load64MiB/1000records/4comparisons';
    S['loadPolicy'] := 'full nonlocalized input; all full dependencies loaded before baseline; consent for session graph; restart to unload';
    B['nativeAcceptancePending'] := True;
  end;
  Result.O['supports'].O['rowBatch'].S['command'] := 'batch.rows';
  with Result.O['supports'].O['subtreeRead'] do begin
    S['command'] := 'elements.subtree';
    B['batchRead'] := True;
    I['maxNodes'] := xeAutomationSubtreeMaxNodes;
    I['maxDepth'] := xeAutomationSubtreeMaxDepth;
    I['visitLimit'] := xeAutomationSubtreeVisitLimit;
    I['responseBytes'] := xeAutomationSubtreeResponseBytes;
    I['signatureScanLimit'] := xeAutomationChildGroupSignatureLimit;
    S['completeness'] := 'logical elements.children preorder; partial limits explicit; no exact total/continuation or preemptible native calls';
  end;
  Result.O['supports'].O['rowBatch'].S['modes'] := 'replace,append,remove; explicit owned source/target payload locators';
  Result.O['supports'].O['rowBatch'].S['scope'] := '1..16 items, multiple disjoint rows per record; 2048 visits, depth16, 256KiB request';
  Result.O['supports'].O['rowBatch'].S['preflight'] := 'matching expectedRevision, native schema/removal gates, missing masters; pinned identities, immutable source records';
  Result.O['supports'].O['rowBatch'].S['persistence'] := 'default dryRun:true; per-item partial outcomes; explicit save and terminal flush';
  Result.O['supports'].O['rowBatch'].S['excluded'] := 'record/header writes, deleted/partial forms, union variant switching, missing ancestor creation, automatic source-absence deletion';
  Result.O['supports'].O['selections'].S['commands'] := 'selections.inspect,copy_into,remove,create_group';
  Result.O['supports'].O['selections'].S['scope'] := '1..16 file/group selectors, <=128 records including implicit copy owners, <=2048 structural nodes, depth<=8; native session groupPath type/label';
  Result.O['supports'].O['selections'].S['copy'] := 'recursive full nondeleted/nonpartial payload overrides, parent-before-child; explicit overwrite/addRequiredMasters; no TES4 header clone; native partial creation off';
  Result.O['supports'].O['selections'].S['removal'] := 'preflight recursive group descendants; native file removal/unload and disk delete unsupported';
  Result.O['supports'].O['selections'].S['persistence'] := 'default dryRun:true; in-memory until explicit save/terminal flush; native save may omit empty groups';
  Result.O['supports'].O['selectiveCleaning'].S['kinds'] := 'cleaning.remove_itm,cleaning.undelete_and_disable_refs';
  Result.O['supports'].O['selectiveCleaning'].S['scope'] := 'target.files:1..8 loaded plugins, <=1000 records; non-TES3, translation-mode-off';
  Result.O['supports'].O['selectiveCleaning'].S['semantics'] := 'default dryRun:true; no master cleanup; retain nonempty child-group parents and deleted NAVM; UDR uses reported native session settings';
  Result.O['supports'].O['selectiveCleaning'].S['persistence'] := 'retained per-record plan/apply outcomes; in-memory until save/terminal flush; between-record cancellation; no rollback';
  Result.O['supports'].O['selectiveCleaning'].S['findings'] := 'immutable planned/skipped/applied events plus terminal per-file counts; latest outcomes in result.files.records; canceled/failed findings incomplete';
  Result.O['supports'].O['cleaningReports'].S['command'] := 'reports.cleaning';
  Result.O['supports'].O['cleaningReports'].S['scope'] := '1..8 saved/flushed source files, <=1000 records, <=64MiB each; clean masters';
  Result.O['supports'].O['cleaningReports'].S['formats'] := 'native loot; native boss only gmTES4';
  Result.O['supports'].O['cleaningReports'].S['effect'] := 'read-only current snapshot with concrete identities/CRC; optional atomic UTF-8 outputDirectory, default dryRun';
  Result.O['supports'].O['automaticVWD'].S['command'] := 'records.set_vwd_from_mesh';
  Result.O['supports'].O['automaticVWD'].S['gamePredicate'] := 'wbIsOblivion; translation-mode-off; native exterior and resource existence';
  Result.O['supports'].O['automaticVWD'].S['scope'] := 'files:1..8, <=1000 records, <=128 eligible; optional targetFile copies eligible selected latest identities';
  Result.O['supports'].O['automaticVWD'].B['defaultsDryRun'] := True;
  Result.O['supports'].O['automaticVWD'].S['existingTargetPolicy'] := 'refuse existing overrides';
  Result.O['supports'].O['modgroups'].S['commands'] := 'modgroups.list/activate/reload/write/refresh_crc';
  Result.O['supports'].O['modgroups'].S['identity'] := 'native-discoverable absolute configFile plus name';
  Result.O['supports'].O['modgroups'].S['persistence'] := 'immediate atomic config; session-only explicit selection; no plugin save';
  Result.O['supports'].O['modgroups'].S['limits'] := '128 groups, 64 items, 32 selections, 16 CRCs per item, 1MiB config';
  Result.O['supports'].O['localization'].S['games'] := 'Skyrim/Fallout4/Fallout76/Starfield';
  Result.O['supports'].O['localization'].S['commands'] := 'localization.tables/get/set/language/convert/save/export_text';
  Result.O['supports'].O['localization'].B['conversionDefaultsDryRun'] := True;
  Result.O['supports'].O['localization'].B['conversionRequiresRestart'] := True;
  Result.O['supports'].O['localization'].S['limits'] := '1000 fields, 100000 visits, 4MiB text; 64MiB tables; 1MiB encoded string';
  Result.O['supports'].O['localization'].S['excluded'] := 'GUI translation vocabulary workflow; new arbitrary table IDs; fallback-decoded lossy saves';

  xeAutomationEnsureCapabilityCommandSurface;
  with Result.O['supports'].O['pipeTransport'] do begin
    I['maxRequestBytes'] := xeAutomationMaxRequestBytes;
    I['maxResponseBytes'] := xeAutomationMaxResponseBytes;
    I['readDeadlineMs'] := xeAutomationReadDeadlineMs;
    I['writeDeadlineMs'] := xeAutomationWriteDeadlineMs;
    I['peerCloseDeadlineMs'] := xeAutomationPeerCloseDeadlineMs;
    I['clientResponseDeadlineMs'] := xeAutomationClientResponseDeadlineMs;
    B['mainThreadWaitsForPeer'] := False;
    B['preemptsCommandExecution'] := False;
    S['framing'] := 'one-json-document-per-message';
  end;
  with Result.O['supports'].O['idempotency'] do begin
    S['sessionId'] := xeAutomationReplaySessionId;
    B['active'] := xeAutomationReplaySessionId <> '';
    S['keyField'] := 'idempotencyKey';
    S['payloadEquality'] := 'exact-utf8-text-including-whitespace-and-correlation';
    S['eviction'] := 'fifo-completed-requests';
    I['maxKeyBytes'] := xeAutomationIdempotencyKeyMaxBytes;
    I['maxEntries'] := xeAutomationReplayMaxEntries;
    I['maxRetainedBytes'] := xeAutomationReplayMaxBytes;
    B['guaranteedAfterEviction'] := False;
    B['survivesSessionExit'] := False;
  end;

  // This contract is intentionally small and mode-agnostic so automation
  // clients can cheaply detect command names and transport support.
  lCommands := Result.A['commands'];
  lCommandNames := xeAutomationListCommands;
  for lCommandName in lCommandNames do
    lCommands.Add(lCommandName);

  Result.O['supports'].B['oneShot'] := True;
  Result.O['supports'].B['daemon'] := True;
  Result.O['supports'].B['pendingSaveReadback'] := True;
  Result.O['supports'].B['sessionFlush'] := True;
  Result.O['supports'].B['sortableContainerNotice'] := True;
  Result.O['supports'].O['commandSchemas'].S['command'] := 'system.command_schema';
  Result.O['supports'].O['commandSchemas'].B['onDemand'] := True;
  xeAutomationWriteSchemaCoverage(Result.O['supports'].O['commandSchemas']);
  Result.O['supports'].O['commandSchemas'].S['exampleAvailabilityField'] := 'exampleAvailable';
  Result.O['supports'].O['editExpectations'].S['revisionSource'] :=
    'session.get_dirty_state.mutationRevision';
  Result.O['supports'].O['editExpectations'].S['valueSource'] :=
    'elements.get_value.values.editValue';
  // Supports fields are explicit protocol metadata rather than inferred from
  // command names so clients can choose safe patch-building flows up front.
  Result.O['supports'].O['filesCreate'].A['extensions'].Add('.esp');
  Result.O['supports'].O['filesCreate'].A['extensions'].Add('.esm');
  Result.O['supports'].O['filesCreate'].A['extensions'].Add('.esl');
  Result.O['supports'].O['filesCreate'].A['flags'].Add('esm');
  Result.O['supports'].O['filesCreate'].A['flags'].Add('esl');
  // Phase 16 (contract 0.21): `small` is a Starfield-native alias of `esl`
  // (both address the same light-slot bit) and `localized` maps to the native
  // IwbFile.IsLocalized header bit. Both stay valid for all games; wrappers
  // can probe supports.filesCreate.aliases to translate names cleanly.
  Result.O['supports'].O['filesCreate'].A['flags'].Add('small');
  Result.O['supports'].O['filesCreate'].A['flags'].Add('medium');
  Result.O['supports'].O['filesCreate'].A['flags'].Add('localized');
  lFilesCreateAliases := Result.O['supports'].O['filesCreate'].O['aliases'];
  lFilesCreateAliases.S['smallAliasOf'] := 'esl';
  // Local fork: surface that Starfield .esp creation/editing/master-add is
  // enabled natively in this build, even though upstream xEdit blocks it.
  // The "plain-only" mode means we only open the unflagged .esp shape
  // (no Light/Medium/Update/ESL flag); flagged-.esp combinations remain
  // blocked because the SF1 engine handles them unstably. The
  // "full-only" master policy means master-add still requires every
  // master to be a Full module - matching xEdit core's existing SF1
  // safety gate at TwbFile.AddMaster.
  if wbIsStarfield then begin
    Result.O['supports'].O['filesCreate'].O['starfieldEspWrite'].S['mode'] := 'plain-only';
    Result.O['supports'].O['filesCreate'].O['starfieldEspWrite'].S['masterPolicy'] := 'full-only';
    Result.O['supports'].O['filesCreate'].O['starfieldEspWrite'].B['allowMasterAdd'] := True;
  end;
  // records.create intentionally has no protocol-side signature allow-list; xEdit's
  // native group/record Add path owns support decisions for the active game mode.
  Result.O['supports'].O['recordsCreate'].S['signaturePolicy'] := 'native-xedit-add';
  Result.O['supports'].O['scripts'].O['namespaces'].A['runnable'].Add('');
  Result.O['supports'].O['scripts'].O['namespaces'].A['runnable'].Add('Agent');
  Result.O['supports'].O['scripts'].O['namespaces'].A['writable'].Add('Agent');
  Result.O['supports'].O['scripts'].S['fsReadRoot'] := 'scripts';
  Result.O['supports'].O['scripts'].B['runtimeFsRead'] := True;
  Result.O['supports'].O['scripts'].B['runtimeFsWrite'] := False;
  Result.O['supports'].O['scripts'].B['runtimeUi'] := False;
  Result.O['supports'].O['scripts'].B['runtimeShell'] := False;
  Result.O['supports'].O['scripts'].B['runtimeClipboard'] := False;
  Result.O['supports'].O['scripts'].B['runtimeProcessSpawn'] := False;
  Result.O['supports'].O['scripts'].A['targetModel'].Add('explicitLocators');
  Result.O['supports'].O['scripts'].A['targetModel'].Add('none');
  Result.O['supports'].O['scripts'].S['lintPolicy'] := 'hard-gate-with-override';
  Result.O['supports'].O['scripts'].S['lintScope'] := 'entry-script-only';
  Result.O['supports'].O['scripts'].O['execution'].B['synchronous'] := True;
  Result.O['supports'].O['scripts'].O['execution'].B['cancelable'] := False;
  Result.O['supports'].O['scripts'].O['execution'].I['defaultTimeoutMs'] := 30000;
  Result.O['supports'].O['scripts'].O['execution'].I['defaultMaxStatements'] := 1000000;
  // The existing shared GUI/daemon runner semantics are exposed as explicit
  // client metadata without moving scripts.run into jobs.*.
  Result.O['supports'].O['scripts'].O['execution'].S['overlapPolicy'] := 'single-process-single-runner';
  Result.O['supports'].O['scripts'].O['execution'].A['busyHolders'].Add('daemon');
  Result.O['supports'].O['scripts'].O['execution'].A['busyHolders'].Add('gui');
  Result.O['supports'].O['scripts'].O['execution'].B['failureMessagesOnError'] := True;
  Result.O['supports'].O['scripts'].O['execution'].B['iKnowWhatImDoing'] := wbIKnowWhatImDoing;
  lScripts := Result.O['supports'].O['scripts'];
  // Additive script-policy fields remain part of the frozen capability surface.
  with lScripts.A['additionalAllowedReads'] do
  begin
    Add('TFile.ReadAllText');
    Add('TStrings.LoadFromFile');
    Add('TMemoryStream.LoadFromFile');
    Add('TDirectory.GetFiles');
    Add('TDirectory.GetDirectories');
  end;
  with lScripts.A['errorLifecycleFields'] do
  begin
    Add('ranInitialize');
    Add('ranFinalize');
    Add('processed');
  end;
  with lScripts.A['additionalDenyCodes'] do
  begin
    Add('script_external_declaration_not_allowed');
  end;
  Result.O['supports'].O['jobs'].A['states'].Add('queued');
  Result.O['supports'].O['jobs'].A['states'].Add('running');
  Result.O['supports'].O['jobs'].A['states'].Add('succeeded');
  Result.O['supports'].O['jobs'].A['states'].Add('failed');
  Result.O['supports'].O['jobs'].A['states'].Add('cancel_requested');
  Result.O['supports'].O['jobs'].A['states'].Add('canceled');
  Result.O['supports'].O['jobs'].A['commands'].Add('jobs.start');
  Result.O['supports'].O['jobs'].A['commands'].Add('jobs.get');
  Result.O['supports'].O['jobs'].A['commands'].Add('jobs.findings');
  Result.O['supports'].O['jobs'].A['commands'].Add('jobs.cancel');
  Result.O['supports'].O['jobs'].A['commands'].Add('jobs.discard');
  with Result.O['supports'].O['jobs'].O['stepping'] do begin
    for lJobKind in xeAutomationListSteppedJobKinds do A['kinds'].Add(lJobKind);
    I['workLimit'] := xeAutomationJobStepWorkLimit;
    I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
    I['depthLimit'] := xeAutomationJobStepDepthLimit;
    S['depthLimitAppliesTo'] := 'validation errors/ITM/deleted refs only; circular graph uses kindLimits; combined cleaning preserves uncapped native file scope';
    with O['kindLimits'].O['validation.circular_leveled_lists'] do begin
      I['depthLimit'] := xeAutomationCircularDepthLimit;
      I['visitedLimit'] := xeAutomationCircularVisitedLimit;
      B['usesSharedNativeTags'] := False;
    end;
    with O['kindLimits'].O['cleaning.remove_itm'] do
      I['mutationLimit'] := xeAutomationSelectiveMutationStepLimit;
    with O['kindLimits'].O['cleaning.undelete_and_disable_refs'] do
      I['mutationLimit'] := xeAutomationSelectiveMutationStepLimit;
    with O['kindLimits'].O['cleaning.quick_clean'] do begin
      I['mutationLimit'] := xeAutomationSelectiveMutationStepLimit;
      S['scope'] := 'full current file; preorder roots retained during each ITM/UDR stage';
    end;
    with O['kindLimits'].O['cleaning.quick_auto_clean'] do begin
      I['mutationLimit'] := xeAutomationSelectiveMutationStepLimit;
      S['scope'] := 'full current file; separate sort/clean master polls, then preorder ITM/UDR stages';
    end;
    with O['kindLimits'].O['cleaning.sort_and_clean_masters'] do begin
      I['mutationLimit'] := xeAutomationSelectiveMutationStepLimit;
      S['scope'] := 'separate indivisible native sort/clean master calls';
    end;
    B['nativeCallsPreemptible'] := False;
    S['progress'] := 'progress.detail describes the retained current/last file; completed counts fully finished targets only';
    S['findings'] := 'findingsComplete only on success; canceled/failed jobs retain partial rows/findings; capacity failures keep admitted findings';
  end;
  with Result.O['supports'].O['lod'] do begin
    S['jobKind'] := 'lod.generate';
    S['target'] := 'worldspaces:1..4 WRLD locators';
    S['options'] := 'operation:generate|splitAtlas; outputRoot:existing absolute directory; objects/trees booleans; settings object';
    S['outputPolicy'] := 'fresh per-world directory; immediate external artifacts; no plugin mutation; independent output verification required';
    S['cancelBoundary'] := 'between worldspaces; current native unit blocks its poll';
    S['settings'] := 'atlasWidth/atlasHeight:1024,2048,4096,8192; textureSize:256,512,1024; brightness:-30..30; alphaThreshold:0..255; trees3D/noTangents/noVertexColors:boolean; lodLevel:4,8,16; x/y:int16 pair';
    S['constraints'] := 'FO76/SF reject; SSE/VR object LOD needs LODGen startup; split Skyrim/FO3/FNV only; 100000 native scan elements; no custom extra-options files; isolated scratch and bounded logs/inventory';
  end;
  // Keep the public job-kind order and membership stable so clients receive a
  // deterministic contract instead of dictionary sort order.
  for lJobKind in xeAutomationFinalJobKinds do
    Result.O['supports'].O['jobs'].A['kinds'].Add(lJobKind);
  Result.O['supports'].O['fileHygiene'].A['commands'].Add('files.get_header');
  Result.O['supports'].O['fileHygiene'].A['commands'].Add('files.get_masters');
  Result.O['supports'].O['fileHygiene'].A['commands'].Add('files.set_header_flags');
  Result.O['supports'].O['fileHygiene'].A['commands'].Add('files.sort_masters');
  Result.O['supports'].O['fileHygiene'].A['commands'].Add('files.clean_masters');
  Result.O['supports'].O['fileHygiene'].A['headerFlags'].Add('esm');
  Result.O['supports'].O['fileHygiene'].A['headerFlags'].Add('esl');
  // Phase 16 (contract 0.21): same alias + localized additions as filesCreate.
  Result.O['supports'].O['fileHygiene'].A['headerFlags'].Add('small');
  Result.O['supports'].O['fileHygiene'].A['headerFlags'].Add('medium');
  Result.O['supports'].O['fileHygiene'].A['headerFlags'].Add('localized');
  lHeaderFlagAliases := Result.O['supports'].O['fileHygiene'].O['aliases'];
  lHeaderFlagAliases.S['smallAliasOf'] := 'esl';
  Result.O['supports'].O['fileHygiene'].S['saveBoundary'] := 'explicit_session_save';

  // Phase 13 element-mutation expansion. See docs/plans/2026-06-07-xedit-phase13-*.md.
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.set_native_value');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.set_to_default');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.clear');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.move_up');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.move_down');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.next_member');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.previous_member');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.edit_capabilities');
  Result.O['supports'].O['elementsMutation'].A['commands'].Add('elements.assign_templates');

  Result.O['supports'].O['elementsMutation'].O['discovery'].S['capabilitiesCommand'] := 'elements.edit_capabilities';
  Result.O['supports'].O['elementsMutation'].O['discovery'].S['templatesCommand']    := 'elements.assign_templates';
  Result.O['supports'].O['elementsMutation'].O['discovery'].B['templatesEmbedded']   := True;
  Result.O['supports'].O['elementsMutation'].O['discovery'].B['sourceSensitiveCopyCheck'] := True;

  Result.O['supports'].O['elementsMutation'].O['valueWrites'].B['editValue'] := True;
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].B['supported']    := True;
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].S['requestShape'] := 'json-typed-with-optional-kind-hint';
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].A['kinds'].Add('int');
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].A['kinds'].Add('float');
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].A['kinds'].Add('string');
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].A['kinds'].Add('bool');
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].A['kinds'].Add('formId');
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].A['kinds'].Add('formIdArray');
  Result.O['supports'].O['elementsMutation'].O['valueWrites'].O['nativeValue'].B['losslessJsonRoundTrip'] := False;

  Result.O['supports'].O['elementsMutation'].O['addChild'].B['targetIndex'] := True;
  Result.O['supports'].O['elementsMutation'].O['addChild'].O['templateSelection'].B['byIndex'] := True;
  Result.O['supports'].O['elementsMutation'].O['addChild'].O['templateSelection'].B['byName']  := True;
  Result.O['supports'].O['elementsMutation'].O['addChild'].O['templateSelection'].B['autoSelectSingleTemplate'] := True;

  Result.O['supports'].O['elementsMutation'].O['copyChildTo'].B['targetIndex'] := True;
  Result.O['supports'].O['elementsMutation'].O['copyChildTo'].O['addRequiredMasters'].B['supported'] := True;
  Result.O['supports'].O['elementsMutation'].O['copyChildTo'].O['addRequiredMasters'].B['default']   := False;
  Result.O['supports'].O['elementsMutation'].O['copyChildTo'].B['sortOrderExposed'] := False;
  Result.O['supports'].O['elementsMutation'].O['copyChildTo'].S['placementMode']    := 'targetIndex';

  Result.O['supports'].O['elementsMutation'].O['operations'].B['setToDefault']     := True;
  Result.O['supports'].O['elementsMutation'].O['operations'].B['clear']            := True;
  Result.O['supports'].O['elementsMutation'].O['operations'].B['moveUp']           := True;
  Result.O['supports'].O['elementsMutation'].O['operations'].B['moveDown']         := True;
  Result.O['supports'].O['elementsMutation'].O['operations'].B['nextMember']       := True;
  Result.O['supports'].O['elementsMutation'].O['operations'].B['previousMember']   := True;

  Result.O['supports'].O['elementsMutation'].S['saveBoundary']    := 'explicit_session_save';
  Result.O['supports'].O['elementsMutation'].S['mutationPolicy']  := 'native-xedit-predicates';
  Result.O['supports'].O['elementsMutation'].B['consentRequired'] := True;
  Result.O['supports'].O['elementsMutation'].B['iKnowWhatImDoing'] := wbIKnowWhatImDoing;

  // Phase 15A exposes ChildGroup traversal as read-only locator metadata; no
  // mutation verbs are implied by this capability block.
  lChildGroupNavigation := Result.O['supports'].O['childGroupNavigation'];
  lChildGroupNavigation.S['prefix'] := '\Child Group';
  lChildGroupNavigation.B['recordLocatorReentry'] := True;
  with lChildGroupNavigation.A['parents'] do begin
    Add('CELL');
    Add('WRLD');
    Add('DIAL');
    Add('QUST');
  end;
  lChildGroupNavigation.S['questAvailableWhen'] := 'wbVWDAsQuestChildren';
  with lChildGroupNavigation.O['subLabels'].A['CELL'] do begin
    Add('Persistent');
    Add('Temporary');
    Add('Visible when Distant');
  end;
  with lChildGroupNavigation.O['subLabels'].A['WRLD'] do begin
    Add('Persistent');
    Add('Block <N>,<N>');
    Add('Block <N>,<N>\Sub-Block <M>,<M>');
  end;
  with lChildGroupNavigation.O['groupTypes'] do begin
    I['WRLD-ChildGroup'] := 1;
    I['Block'] := 4;
    I['Sub-Block'] := 5;
    I['CELL-ChildGroup'] := 6;
    I['DIAL-ChildGroup'] := 7;
    I['CELL-Persistent'] := 8;
    I['CELL-Temporary'] := 9;
    I['CELL-VWD'] := 10;
    I['QUST-ChildGroup'] := 10;
  end;
  lChildGroupNavigation.S['objectKind'] := 'child_group';

  // elements.children is now bounded at the verb layer so dense ChildGroups stay
  // safely below the named-pipe buffer limit without changing the transport.
  lElementsChildrenPagination := Result.O['supports'].O['elementsChildrenPagination'];
  lElementsChildrenPagination.I['defaultLimit'] := 200;
  lElementsChildrenPagination.I['maxLimit'] := 1000;
  with lElementsChildrenPagination.A['responseFields'] do begin
    Add('count');
    Add('total');
    Add('offset');
    Add('truncated');
  end;

  // Phase 15B keeps records.apply_filter as the discovery surface: parentFormId
  // scopes by MainRecord ancestry, while regex fields are explicit alternatives
  // to the existing glob patterns and report timeout skips through result metadata.
  lApplyFilterExtensions := Result.O['supports'].O['applyFilterExtensions'];
  lApplyFilterExtensions.S['nativePredicateDiscovery'] := 'records.filter_options';
  lApplyFilterExtensions.S['scope'] := 'query only; no GUI filter or saved preset changes';
  lApplyFilterExtensions.B['parentFormId'] := True;
  lApplyFilterRegex := lApplyFilterExtensions.O['regex'];
  lApplyFilterRegex.S['engine'] := 'System.RegularExpressions.TRegEx';
  lApplyFilterRegex.I['perRecordTimeoutMs'] := 100;
  lApplyFilterRegex.I['requestBudgetMs'] := 250;
  lApplyFilterRegex.I['maxMatchAttempts'] := 1000;
  lApplyFilterRegex.I['maxPatternLength'] := 256;
  lApplyFilterRegex.B['terminatesTimedOutWorker'] := False;
  lApplyFilterRegex.S['uncertainOutcome'] := 'complete:false,incompleteReason';
  with lApplyFilterRegex.A['fields'] do begin
    Add('editorIdRegex');
    Add('displayNameRegex');
    Add('fullNameRegex');
    Add('baseEditorIdRegex');
    Add('baseDisplayNameRegex');
  end;
  lApplyFilterRegex.S['anchoring'] := 'partial';
  lApplyFilterRegex.B['caseSensitive'] := False;
  lApplyFilterRegex.S['combinedWithPattern'] := 'rejected';
  lApplyFilterExtensions.S['regexTimeoutsField'] := 'result.regexTimeouts';
  lApplyFilterMultiPattern := lApplyFilterExtensions.O['multiPattern'];
  lApplyFilterMultiPattern.B['acceptScalar'] := True;
  lApplyFilterMultiPattern.B['acceptArray'] := True;
  lApplyFilterMultiPattern.I['maxArrayLength'] := 32;
  lApplyFilterMultiPattern.S['semantics'] := 'OR';
  with lApplyFilterMultiPattern.A['appliesTo'] do begin
    Add('editorIdPattern');
    Add('editorIdRegex');
    Add('displayNamePattern');
    Add('displayNameRegex');
    Add('fullNamePattern');
    Add('fullNameRegex');
    Add('baseEditorIdPattern');
    Add('baseEditorIdRegex');
    Add('baseDisplayNamePattern');
    Add('baseDisplayNameRegex');
  end;

  // Phase 16 (contract 0.21) fixes issue #4: records.apply_filter now honors
  // offset for cursor-style drain. Per-page limit stays capped at 100 so
  // response envelopes remain predictable regardless of match cardinality,
  // and total is intentionally omitted -- the underlying scan is early-exit
  // and cannot cheaply produce a full count without breaking the containment
  // guarantee. Wrappers page forward with offset+count until truncated=false.
  lApplyFilterPagination := lApplyFilterExtensions.O['pagination'];
  lApplyFilterPagination.I['defaultLimit'] := 100;
  lApplyFilterPagination.I['maxLimit'] := 100;
  lApplyFilterPagination.I['defaultOffset'] := 0;
  lApplyFilterPagination.S['cursorField'] := 'nextCursor';
  lApplyFilterPagination.B['offsetCompatibility'] := True;
  lApplyFilterPagination.S['revisionBinding'] := 'native-plugin-modification-generation';
  lApplyFilterPagination.I['maxActiveCursors'] := 32;
  lApplyFilterPagination.I['cursorLifetimeMs'] := 300000;
  lApplyFilterPagination.I['maxRetainedBytes'] := 67108864;
  lApplyFilterPagination.I['maxScannedPerPage'] := 5000;
  lApplyFilterPagination.I['scanBudgetMs'] := 100;
  lApplyFilterPagination.B['emptyContinuationPagesPossible'] := True;
  lApplyFilterPagination.B['consumesPageTokens'] := True;
  lApplyFilterPagination.S['retryRule'] := 'repeat-exact-request-with-idempotency-key';
  lApplyFilterPagination.B['emitsTotal'] := False;
  with lApplyFilterPagination.A['responseFields'] do begin
    Add('count');
    Add('offset');
    Add('limit');
    Add('truncated');
    Add('nextOffset');
    Add('nextCursor');
    Add('complete');
    Add('incomplete');
    Add('incompleteReason');
  end;

  // records.references recursion is opt-in so legacy relationship lookups stay
  // shallow unless a caller explicitly asks to union ChildGroup-owned records.
  lReferencesRecursive := Result.O['supports'].O['referencesRecursive'];
  lReferencesRecursive.B['defaultRecursive'] := False;
  with lReferencesRecursive.A['appliesTo'] do begin
    Add('CELL');
    Add('WRLD');
    Add('DIAL');
    Add('QUST');
  end;
  lReferencesRecursive.S['dedupBy'] := 'file-and-loadOrderFormId';
  with Result.O['supports'].O['recordQueryPagination'] do begin
    A['commands'].Add('records.list');
    A['commands'].Add('records.apply_filter');
    A['commands'].Add('records.references');
    A['commands'].Add('records.referenced_by');
    I['defaultLimit'] := 100;
    I['maxLimit'] := 500;
    S['cursorArg'] := 'cursor';
    S['continuationField'] := 'nextCursor';
    B['reverseIndexRequired'] := True;
  end;
  with Result.O['supports'].O['responseProjection'] do begin
    S['fieldsArg'] := 'fields';
    S['relationsArg'] := 'includeRelations';
    B['defaultIncludesRelations'] := True;
    B['preservesLocatorsAndCompleteness'] := True;
    B['compactWireJson'] := True;
  end;
  lReferencesRecursive.S['limitSemantics'] := 'post-union-post-dedup';

  // records.conflict_status now surfaces aggregate conflict signal from the
  // existing ChildGroup seam without changing the main record conflict block.
  lConflictStatusChildGroup := Result.O['supports'].O['conflictStatusChildGroup'];
  lConflictStatusChildGroup.S['subBlockKey'] := 'childGroup';
  with lConflictStatusChildGroup.A['fields'] do begin
    Add('count');
    Add('hasConflict');
    Add('signatures');
    Add('conflictingHits');
    Add('conflictingHitsTruncated');
  end;
  lConflictStatusChildGroup.I['conflictingHitsMax'] := 20;
  lConflictStatusChildGroup.S['omittedWhen'] := 'no-child-group-or-empty-child-group';

  // records.create parent-spec is an opt-in write-side route into existing
  // ChildGroup owners; native xEdit Add still owns per-signature validity.
  lCreateParentSpec := Result.O['supports'].O['createParentSpec'];
  with lCreateParentSpec.A['supportedParents'] do begin
    Add('CELL');
    Add('DIAL');
    Add('QUST');
    Add('WRLD');
  end;
  // 0.18 made WRLD parent-spec supported, but older 0.16 clients may still probe
  // these fields. Keep the additive shape: an empty unsupported list plus an
  // explicit sentinel says the former WRLD deferral is superseded, not removed.
  with lCreateParentSpec.A['unsupportedParents'] do begin
  end;
  lCreateParentSpec.S['wrldDeferralReason'] := 'superseded-by-0.18';
  with lCreateParentSpec.O['subGroupVocabulary'].A['CELL'] do begin
    Add('Persistent');
    Add('Temporary');
    Add('Visible when Distant');
  end;
  with lCreateParentSpec.O['defaultSubGroup'].O['CELL'] do begin
    S['REFR'] := 'Temporary';
    S['ACHR'] := 'Temporary';
    S['PGRD'] := 'Temporary';
    S['LAND'] := 'Temporary';
    S['NAVM'] := 'Temporary';
    S['_other_'] := 'Persistent';
  end;
  lCreateParentSpec.O['subGroupVocabulary'].A['WRLD'].Add('Persistent');
  lCreateParentSpec.B['wrldCoords'] := True;
  lCreateParentSpec.B['wrldRequiresCellSignature'] := True;

  // Reverse navigation is intentionally opt-in because parent arrays multiply
  // response size on enumeration verbs. The relation entries reuse standard shallow
  // record summaries and are ordered from immediate owner outward.
  lReverseNavigation := Result.O['supports'].O['reverseNavigation'];
  lReverseNavigation.S['optInArg'] := 'includeParents';
  with lReverseNavigation.A['appliesTo'] do begin
    Add('records.get');
    Add('records.find_by_form_id');
    Add('records.find_by_editor_id');
    Add('records.master_or_self');
    Add('records.winning_override');
    Add('elements.get');
    Add('elements.children');
    Add('elements.subtree');
  end;
  lReverseNavigation.I['maxAncestorDepth'] := 16;
  lReverseNavigation.S['ordering'] := 'nearest-first';
  lReverseNavigation.S['relationKey'] := 'parents';

  // r5 (contract 0.12): expose the inline string-decoding policy so MCP
  // clients can detect that this fork autodetects UTF-8 for translatable
  // fields and so callers know which startup flags switch the global default.
  Result.O['supports'].O['stringDecoding'].B['translatableInlineUtf8Autodetect'] := True;
  // defaultFallbackEncoding names the encoding the autodetect falls through to
  // when no per-def / per-file / CLI override applies. activeFallbackEncoding
  // reports the encoding currently in effect for the running daemon - it
  // changes when -cp:<...> / -cp-trans:<...> are passed at startup or when
  // the game language sets a non-1252 default through wbEncodingForLanguage.
  Result.O['supports'].O['stringDecoding'].S['defaultFallbackEncoding'] := 'cp1252';
  if Assigned(wbEncodingTrans) then
    Result.O['supports'].O['stringDecoding'].S['activeFallbackEncoding'] := wbEncodingTrans.EncodingName
  else
    Result.O['supports'].O['stringDecoding'].S['activeFallbackEncoding'] := 'cp1252';
  Result.O['supports'].O['stringDecoding'].S['asciiBehavior']       := 'cp1252-path-preserved';
  Result.O['supports'].O['stringDecoding'].A['autodetectScope'].Add('dfTranslatable');
  // Defense layers (RFC 3629 strict + heuristics) - clients can audit
  // expected behavior against these named layers when filing regressions.
  with Result.O['supports'].O['stringDecoding'].A['defenseLayers'] do begin
    Add('rfc3629-strict');
    Add('overlong-tightening');
    Add('surrogate-rejection');
    Add('noncharacter-rejection');
    Add('c1-control-rejection');
    Add('ascii-bypass');
    Add('bom-strip-leading');
  end;
  // Explicit per-file/per-def overrides always win. Latched-boolean check on
  // IwbFile, so explicit cp1252 still suppresses autodetect.
  with Result.O['supports'].O['stringDecoding'].A['overrideWins'] do begin
    Add('cpoverride-sidecar');
    Add('snam-cp-marker');
    Add('per-def-encoding-override');
  end;
  // Startup-only CLI flags that switch the global default encoding before any
  // plugin load. Already-shipped flags - documented here as supported.
  with Result.O['supports'].O['stringDecoding'].O['cliFlags'] do begin
    A['translatableDefault'].Add('-cp:<encoding>');
    A['translatableDefault'].Add('-cp-trans:<encoding>');
    A['nonTranslatableDefault'].Add('-cp-general:<encoding>');
    A['acceptedValues'].Add('utf-8');
    A['acceptedValues'].Add('utf8');
    A['acceptedValues'].Add('65001');
    A['acceptedValues'].Add('1252');
    A['acceptedValues'].Add('936');
    A['acceptedValues'].Add('932');
    A['acceptedValues'].Add('1251');
    A['acceptedValues'].Add('<any-windows-codepage-number>');
    S['scope'] := 'startup-only';
  end;
  Result.O['supports'].O['stringDecoding'].S['readWriteAsymmetry'] := 'none-for-inline-strings';
  Result.O['supports'].O['stringDecoding'].B['rejectsLossyWrites'] := True;
  Result.O['supports'].O['fullElementValues'].S['command'] := 'elements.get_value';
  with Result.O['supports'].O['reachability'] do begin
    S['kind'] := 'analysis.reachability';
    S['target'] := 'files:1..32 report plugins <=1000 records; roots:0..32 additional record locators';
    S['scope'] := 'all loaded plugins; native game roots plus optional roots';
    S['limits'] := '256 loaded files, 1000000 loaded records, 5000000 reset/reach visits per stage; reference indexing is a native blocking unit; cancel between stages';
    S['validity'] := 'succeeded snapshot only; dry run plans without analysis; incomplete flags unavailable';
    S['persistence'] := 'derived memory flags only; plugins unchanged';
  end;
  Result.O['supports'].O['fullElementValues'].I['maxCharacters'] := 1048576;
  Result.O['supports'].O['fullElementValues'].I['maxNativeArrayItems'] := 50000;
  Result.O['supports'].O['fullElementValues'].B['preservesWhitespace'] := True;

end;

function xeAutomationSystemDiagnostics(const Args: TJsonObject): TJsonObject;
  procedure Exclude(const Name, Handler, Availability, Reason, Alternative: string);
  begin
    with Result.A['diagnostics'].AddObject do begin
      S['name'] := Name; S['nativeHandler'] := Handler;
      B['supported'] := False; S['status'] := 'intentionally-excluded';
      S['nativeAvailability'] := Availability; S['reason'] := Reason;
      S['alternative'] := Alternative; S['automationEffect'] := 'none';
    end;
  end;
begin
  Result := TJsonObject.Create;
  Result.S['scope'] := 'source-audited specialized GUI actions; exclusion applies in every automation game/build';
  Result.S['persistence'] := 'read-only catalog; excluded operations never execute GUI callbacks';
  Exclude('test', 'TfrmMain.mniNavTestClick', 'DebugHook-dependent visibility; older alternate handlers are commented out',
    'Active experiment selects Files[2] and prefixes EditorIDs with Hummer; no explicit target contract or diagnostic semantics',
    'validation.check_for_errors; explicit record queries and consented element edits');
  Exclude('bandit_fix', 'TfrmMain.mniNavBanditFixClick', 'hidden legacy mod-specific SCPT/NPC workflow',
    'Hardcoded Mart''s Monster Mod.esm and four named CSNPC scripts; unchecked script pointers and naming-dependent mutation',
    'explicit scoped scripts.run with reviewed script; no automatic equivalent');
  Exclude('race_lvli_fix', 'TfrmMain.mniNavRaceLVLIsClick', 'hidden legacy race-specific LVLI mutation',
    'Infers races and leveled-list replacements from EditorID conventions across loaded files without a general target contract',
    'validation.circular_leveled_lists; explicit FormID/reference plans for intentionally selected replacements');
end;

function xeAutomationSystemRunDiagnostic(const Args: TJsonObject): TJsonObject;
var Catalog, Details, Row: TJsonObject; Name: string; i: Integer;
begin
  Name := xeAutomationRequireStringArg(Args, 'name');
  Catalog := xeAutomationSystemDiagnostics(nil);
  try
    for i := 0 to Catalog.A['diagnostics'].Count - 1 do begin
      Row := Catalog.A['diagnostics'].O[i];
      if not SameText(Name, Row.S['name']) then Continue;
      // Exclusions are enforced, not merely advisory capability labels. Never
      // dispatch hidden callbacks whose implicit selections can mutate files.
      Details := Row.Clone;
      try
        Details.S['gameMode'] := GetEnumName(TypeInfo(TwbGameMode), Ord(wbGameMode));
        raise xeAutomationNewError('unsupported_diagnostic', Row.S['reason'], Details);
      finally Details.Free; end;
    end;
    raise xeAutomationInvalidRequest('Unknown diagnostic; inspect system.diagnostics');
  finally Catalog.Free; end;
end;

initialization
  // System commands self-register because they are safe before data loading.
  // Loaded-data command groups are linked here but registered through explicit
  // startup/capability seams so duplicate registration remains avoidable.
  xeAutomationRegisterCommand('system.ping', xeAutomationSystemPing);
  xeAutomationRegisterCommand('system.describe', xeAutomationSystemDescribe);
  xeAutomationRegisterCommand('system.command_schema', xeAutomationSystemCommandSchema);
  xeAutomationRegisterCommand('system.capabilities', xeAutomationSystemCapabilities);
  xeAutomationRegisterCommand('system.diagnostics', xeAutomationSystemDiagnostics);
  xeAutomationRegisterCommand('system.run_diagnostic', xeAutomationSystemRunDiagnostic);

end.
