{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsPluginAnalysis;

interface

const
  xeAutomationEslScanWorkLimit = 1000000;
  xeAutomationEslScanRecordLimit = 100000;
  xeAutomationCompactEdgeLimit = 100000;

procedure xeAutomationRegisterPluginAnalysisCommands;

implementation

uses
  System.Generics.Collections,
  SysUtils,
  Classes,
  System.Diagnostics,
  JsonDataObjects,
  wbInterface,
  wbLoadOrder,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationJobs,
  xeAutomationMutationAudit,
  xeAutomationMutationPolicy,
  xeAutomationObjectModel;

const
  xeAutomationEslAnalyzeKind = 'plugin.esl.analyze';
  xeAutomationFormIdsCompactForEslKind = 'plugin.formids.compact_for_esl';
  xeAutomationEslApplyKind = 'plugin.esl.apply';
  xeAutomationLightObjectIdLimit = $FFF;

type
  TxeAutomationFormIdRemap = record
    RecordRef: IwbMainRecord;
    OldFormID: TwbFormID;
    NewFormID: TwbFormID;
  end;

  TxeAutomationFormIdRemaps = array of TxeAutomationFormIdRemap;

function xeAutomationLightObjectIdLowest(const AFile: IwbFile): Cardinal;
begin
  Result := $800;
  if Assigned(AFile) and AFile.AllowHardcodedRangeUse then
    Result := 1;
end;

function xeAutomationLightObjectIdCapacity(const AFile: IwbFile): Cardinal;
var
  lLowestObjectId: Cardinal;
begin
  lLowestObjectId := xeAutomationLightObjectIdLowest(AFile);
  if lLowestObjectId > xeAutomationLightObjectIdLimit then
    Exit(0);
  Result := Succ(xeAutomationLightObjectIdLimit - lLowestObjectId);
end;

function xeAutomationObjectIdHex(const AObjectId: Cardinal): string;
begin
  Result := IntToHex(AObjectId, 8);
end;

function xeAutomationProtectedAnalysisTargetMessage(const AFile: IwbFile): string;
var
  lModule: PwbModuleInfo;
begin
  Result := '';
  if not Assigned(AFile) then
    Exit('Automation analysis target is required');

  if AFile.IsNotPlugin then
    Exit(Format('Automation analysis target is not a plugin: %s', [AFile.FileName]));

  lModule := PwbModuleInfo(AFile.ModuleInfo);
  if Assigned(lModule) and (mfIsHardcoded in lModule^.miFlags) then
    Exit(Format('Automation analysis target is a hardcoded module: %s', [AFile.FileName]));

  if fsIsHardcoded in AFile.FileStates then
    Exit(Format('Automation analysis target is a hardcoded file: %s', [AFile.FileName]));

  if fsIsGameMaster in AFile.FileStates then
    Exit(Format('Automation analysis target is the game master: %s', [AFile.FileName]));

  if fsIsOfficial in AFile.FileStates then
    Exit(Format('Automation analysis target is an official master: %s', [AFile.FileName]));
end;

procedure xeAutomationAddFindingObject(const AList: TJsonArray; const ACode, ASeverity, AMessage: string);
var
  lFinding: TJsonObject;
begin
  lFinding := TJsonObject.Create;
  try
    lFinding.S['code'] := ACode;
    lFinding.S['severity'] := ASeverity;
    lFinding.S['message'] := AMessage;
    AList.Add(lFinding);
    lFinding := nil;
  finally
    lFinding.Free;
  end;
end;

procedure xeAutomationAddPagedFinding(const AFindings: TJsonArray; const AFileName, ACode, ASeverity, AMessage: string);
var
  lFinding: TJsonObject;
begin
  lFinding := TJsonObject.Create;
  try
    lFinding.S['severity'] := ASeverity;
    lFinding.S['code'] := ACode;
    lFinding.S['message'] := AMessage;
    lFinding.O['target'].S['file'] := AFileName;
    lFinding.S['source'] := xeAutomationEslAnalyzeKind;
    xeAutomationAppendJobFinding(AFindings, lFinding);
    lFinding := nil;
  finally
    lFinding.Free;
  end;
end;

procedure xeAutomationAddUniqueString(const ATarget: TJsonArray; const AValue: string);
var
  i: Integer;
begin
  for i := 0 to Pred(ATarget.Count) do
    if SameText(ATarget.S[i], AValue) then
      Exit;
  ATarget.Add(AValue);
end;

function xeAutomationNewHeaderFlags(const AFile: IwbFile): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.B['esm'] := AFile.IsESM;
  Result.B['esl'] := AFile.IsLight;
  Result.B['medium'] := AFile.IsMedium;
end;

function xeAutomationReadBooleanOption(const AOptions: TJsonObject; const AName: string; const ADefault: Boolean): Boolean;
begin
  Result := ADefault;
  if not Assigned(AOptions) or not AOptions.Contains(AName) then
    Exit;
  if AOptions.Types[AName] <> jdtBool then
    raise xeAutomationInvalidRequest(Format('Automation option "%s" must be a boolean', [AName]));
  Result := AOptions.B[AName];
end;

function xeAutomationAppliedWord(const AApplied: Boolean): string;
begin
  if AApplied then
    Result := 'Applied'
  else
    Result := 'Planned';
end;

procedure xeAutomationAddDirtyFile(const ADirtyFiles: TJsonArray; const AFile: IwbFile);
begin
  if Assigned(AFile) then
    xeAutomationAddUniqueString(ADirtyFiles, AFile.FileName);
end;

procedure xeAutomationValidateEslAnalyzeStart(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
var names: TStringList; fileRef: IwbFile; files: TJsonArray; i: Integer;
begin
  if not Assigned(ATarget) or not ATarget.Contains('files') or (ATarget.Types['files'] <> jdtArray) then
    raise xeAutomationInvalidRequest('plugin.esl.analyze target.files must be a plugin name array');
  if ATarget.Count <> 1 then raise xeAutomationInvalidRequest('plugin.esl.analyze target accepts only files');
  if Assigned(AOptions) and (AOptions.Count > 0) then raise xeAutomationInvalidRequest('plugin.esl.analyze options must be empty');
  files := ATarget.A['files'];
  if (files.Count < 1) or (files.Count > 256) then raise xeAutomationInvalidRequest('plugin.esl.analyze selects 1..256 files');
  names := TStringList.Create;
  try
    names.CaseSensitive := False;
    for i := 0 to files.Count - 1 do begin
      if files.Types[i] <> jdtString then raise xeAutomationInvalidRequest('plugin.esl.analyze files entries must be strings');
      fileRef := xeAutomationRequirePluginFile(Trim(files.S[i]));
      if names.IndexOf(fileRef.FileName) >= 0 then raise xeAutomationInvalidRequest('Duplicate plugin.esl.analyze target');
      names.Add(fileRef.FileName);
    end;
  finally names.Free; end;
  if not ADryRunSpecified then ADryRun := True;
end;

procedure xeAutomationValidatePluginFilesTarget(const AKind: string; var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget: TJsonObject);
var
  lFiles: TJsonArray;
  i: Integer;
begin
  if not Assigned(ATarget) then
    raise xeAutomationInvalidRequest(Format('Automation %s target is required', [AKind]));
  if not ATarget.Contains('files') then
    raise xeAutomationInvalidRequest(Format('Automation %s target.files is required', [AKind]));
  if ATarget.Types['files'] <> jdtArray then
    raise xeAutomationInvalidRequest(Format('Automation %s target.files must be an array', [AKind]));

  lFiles := ATarget.A['files'];
  if lFiles.Count = 0 then
    raise xeAutomationInvalidRequest(Format('Automation %s target.files must not be empty', [AKind]));
  for i := 0 to Pred(lFiles.Count) do
    if lFiles.Types[i] <> jdtString then
      raise xeAutomationInvalidRequest(Format('Automation %s target.files entries must be strings', [AKind]));

  // Mutating 6B jobs are safe-by-default: callers must opt into apply mode with
  // dryRun:false, and persistence still remains a separate session.save call.
  if not ADryRunSpecified then
    ADryRun := True;
end;

procedure xeAutomationValidateEslMutationTargets(const kind: string; var ADryRun: Boolean;
  const ADryRunSpecified: Boolean; const ATarget: TJsonObject);
var names: TStringList; fileRef: IwbFile; i: Integer;
begin
  xeAutomationValidatePluginFilesTarget(kind, ADryRun, ADryRunSpecified, ATarget);
  if ATarget.Count <> 1 then raise xeAutomationInvalidRequest(kind + ' target accepts only files');
  if ATarget.A['files'].Count > 256 then
    raise xeAutomationInvalidRequest(kind + ' selects 1..256 files');
  names := TStringList.Create;
  try
    names.CaseSensitive := False;
    for i := 0 to ATarget.A['files'].Count - 1 do begin
      fileRef := xeAutomationRequirePluginFile(Trim(ATarget.A['files'].S[i]));
      if names.IndexOf(fileRef.FileName) >= 0 then raise xeAutomationInvalidRequest('Duplicate ' + kind + ' target');
      names.Add(fileRef.FileName);
      if not ADryRun then xeAutomationRequireWritableEslMutationTarget(fileRef);
    end;
  finally names.Free; end;
end;

procedure xeAutomationValidateCompactForEslStart(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
begin
  if Assigned(AOptions) and (AOptions.Count <> 0) then
    raise xeAutomationInvalidRequest('Compaction options must be empty');
  xeAutomationValidateEslMutationTargets(xeAutomationFormIdsCompactForEslKind, ADryRun, ADryRunSpecified, ATarget);
end;

procedure xeAutomationValidateEslApplyStart(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
begin
  // Same bounded, resolved, unique file scope and writable apply preflight as compact.
  xeAutomationValidateEslMutationTargets(xeAutomationEslApplyKind, ADryRun, ADryRunSpecified, ATarget);
  if Assigned(AOptions) and ((AOptions.Count > 1) or
     ((AOptions.Count = 1) and not AOptions.Contains('allowAfterCompact'))) then
    raise xeAutomationInvalidRequest('ESL apply options accept only allowAfterCompact');
  xeAutomationReadBooleanOption(AOptions, 'allowAfterCompact', False);
end;

procedure xeAutomationAddEslRecordStats(const AFile: IwbFile; const ARecord: IwbMainRecord;
  const ASeenRecords: TDictionary<Cardinal, Boolean>; var ANewRecordCount: Integer; var AMaxObjectId: Cardinal;
  var AMinObjectId: Cardinal; var AHasCellRisk: Boolean);
var
  lObjectId: Cardinal;
begin
  if not Assigned(ARecord) or (ARecord = AFile.Header) then
    Exit;

  if ARecord.LoadOrderFormID.FileID <> AFile.LoadOrderFileID then
    Exit;

  if ASeenRecords.ContainsKey(ARecord.LoadOrderFormID.ToCardinal) then
    Exit;
  ASeenRecords.Add(ARecord.LoadOrderFormID.ToCardinal, True);

  Inc(ANewRecordCount);
  lObjectId := ARecord.LoadOrderFormID.ObjectID;
  if (AMinObjectId = 0) or (lObjectId < AMinObjectId) then
    AMinObjectId := lObjectId;
  if lObjectId > AMaxObjectId then
    AMaxObjectId := lObjectId;
  if ARecord.Signature = 'CELL' then
    AHasCellRisk := True;
end;

procedure xeAutomationCollectEslRecordStatsFromElement(const AFile: IwbFile; const AElement: IwbElement;
  const ASeenRecords: TDictionary<Cardinal, Boolean>; var ANewRecordCount: Integer; var AMaxObjectId: Cardinal;
  var AMinObjectId: Cardinal; var AHasCellRisk: Boolean);
var
  lRecord: IwbMainRecord;
  lContainer: IwbContainer;
  i: Integer;
begin
  if not Assigned(AElement) then
    Exit;

  if Supports(AElement, IwbMainRecord, lRecord) then
    xeAutomationAddEslRecordStats(AFile, lRecord, ASeenRecords, ANewRecordCount, AMaxObjectId, AMinObjectId, AHasCellRisk);

  // New records created through automation live under signature GRUP containers.
  // Walk the file tree instead of trusting the shallow Records[] view so analysis
  // remains read-only but still sees freshly-created grouped records before save.
  if Supports(AElement, IwbContainer, lContainer) then
    for i := 0 to Pred(lContainer.ElementCount) do
      xeAutomationCollectEslRecordStatsFromElement(AFile, lContainer.Elements[i], ASeenRecords, ANewRecordCount, AMaxObjectId,
        AMinObjectId, AHasCellRisk);
end;

procedure xeAutomationCollectEslRecordStatsFromVisibleGroups(const AFile: IwbFile;
  const ASeenRecords: TDictionary<Cardinal, Boolean>; var ANewRecordCount: Integer; var AMaxObjectId: Cardinal;
  var AMinObjectId: Cardinal; var AHasCellRisk: Boolean);
var
  lContainer: IwbContainer;
  lGroup: IwbGroupRecord;
  i: Integer;
begin
  if not Supports(AFile, IwbContainer, lContainer) then
    Exit;

  for i := 0 to Pred(lContainer.ElementCount) do
    if Supports(lContainer.Elements[i], IwbGroupRecord, lGroup) then
      xeAutomationCollectEslRecordStatsFromElement(AFile, lGroup, ASeenRecords, ANewRecordCount, AMaxObjectId, AMinObjectId,
        AHasCellRisk);
end;

procedure xeAutomationCollectEslRecordStatsByObjectIdScan(const AFile: IwbFile;
  const ASeenRecords: TDictionary<Cardinal, Boolean>; var ANewRecordCount: Integer; var AMaxObjectId: Cardinal;
  var AMinObjectId: Cardinal; var AHasCellRisk: Boolean);
var
  lObjectId: Cardinal;
  lFormId: TwbFormID;
  lRecord: IwbMainRecord;
begin
  if AFile.HighObjectID > $FFFF then
    Exit;

  for lObjectId := 1 to AFile.HighObjectID do begin
    lFormId := TwbFormID.FromCardinal(lObjectId).ChangeFileID(AFile.LoadOrderFileID);
    lRecord := AFile.RecordByFormID[lFormId, True, True];
    if Assigned(lRecord) then
      xeAutomationAddEslRecordStats(AFile, lRecord, ASeenRecords, ANewRecordCount, AMaxObjectId, AMinObjectId, AHasCellRisk);
  end;
end;

function xeAutomationDescribeEslStats(const AFile: IwbFile; const AFindings: TJsonArray;
  lNewRecordCount: Integer; lMaxObjectId, lMinObjectId: Cardinal; lHasCellRisk: Boolean): TJsonObject;
var
  lProtectedMessage: string;
  lRiskMessage: string;
  lBlockerMessage: string;
  lNextObjectId: Cardinal;
  lLowestObjectId: Cardinal;
  lLightObjectIdCapacity: Cardinal;
begin
  Result := TJsonObject.Create;
  try
    Result.S['fileName'] := AFile.FileName;
    Result.B['eligible'] := True;
    Result.B['canSetLightFlagWithoutCompact'] := True;
    Result.B['requiresCompact'] := False;
    Result.S['lightObjectIdLowest'] := xeAutomationObjectIdHex(xeAutomationLightObjectIdLowest(AFile));
    Result.S['lightObjectIdLimit'] := xeAutomationObjectIdHex(xeAutomationLightObjectIdLimit);
    Result.I['lightObjectIdCapacity'] := xeAutomationLightObjectIdCapacity(AFile);
    Result.A['risks'].Clear;
    Result.A['blockers'].Clear;

    lNextObjectId := AFile.NextObjectID and $FFFFFF;
    if (lNextObjectId > 0) and (Pred(lNextObjectId) > lMaxObjectId) then
      lMaxObjectId := Pred(lNextObjectId);

    Result.I['newRecordCount'] := lNewRecordCount;
    Result.S['minObjectId'] := xeAutomationObjectIdHex(lMinObjectId);
    Result.S['maxObjectId'] := xeAutomationObjectIdHex(lMaxObjectId);
    lLowestObjectId := xeAutomationLightObjectIdLowest(AFile);
    lLightObjectIdCapacity := xeAutomationLightObjectIdCapacity(AFile);

    if not wbIsLightSupported then begin
      lBlockerMessage := 'Current game mode does not support light plugins';
      xeAutomationAddFindingObject(Result.A['blockers'], xeAutomationFindingUnsupportedGameMode, 'error', lBlockerMessage);
      xeAutomationAddPagedFinding(AFindings, AFile.FileName, xeAutomationFindingUnsupportedGameMode, 'error', lBlockerMessage);
    end;

    lProtectedMessage := xeAutomationProtectedAnalysisTargetMessage(AFile);
    if lProtectedMessage <> '' then begin
      xeAutomationAddFindingObject(Result.A['blockers'], xeAutomationFindingProtectedTarget, 'error', lProtectedMessage);
      xeAutomationAddPagedFinding(AFindings, AFile.FileName, xeAutomationFindingProtectedTarget, 'error', lProtectedMessage);
    end;

    if not AFile.IsEditable then begin
      lBlockerMessage := Format('Automation analysis target is read-only: %s', [AFile.FileName]);
      xeAutomationAddFindingObject(Result.A['blockers'], xeAutomationFindingNonEditableTarget, 'error', lBlockerMessage);
      xeAutomationAddPagedFinding(AFindings, AFile.FileName, xeAutomationFindingNonEditableTarget, 'error', lBlockerMessage);
    end;

    if Cardinal(lNewRecordCount) > lLightObjectIdCapacity then begin
      lBlockerMessage := Format('%s has %d new records, exceeding the light plugin ObjectID capacity of %d',
        [AFile.FileName, lNewRecordCount, lLightObjectIdCapacity]);
      xeAutomationAddFindingObject(Result.A['blockers'], xeAutomationFindingTooManyNewRecordsForLight, 'error', lBlockerMessage);
      xeAutomationAddPagedFinding(AFindings, AFile.FileName, xeAutomationFindingTooManyNewRecordsForLight, 'error', lBlockerMessage);
    end;

    // Analysis and compaction must share the same usable ObjectID range. For games
    // that reserve the hardcoded range, records below $800 also require compaction.
    if (lNewRecordCount > 0) and ((lMaxObjectId > xeAutomationLightObjectIdLimit) or (lMinObjectId < lLowestObjectId)) then begin
      Result.B['canSetLightFlagWithoutCompact'] := False;
      Result.B['requiresCompact'] := True;
      lRiskMessage := Format('%s contains new records above the light ObjectID limit and requires FormID compaction before setting ESL',
        [AFile.FileName]);
      xeAutomationAddFindingObject(Result.A['risks'], xeAutomationFindingRequiresFormIDCompaction, 'warning', lRiskMessage);
      xeAutomationAddPagedFinding(AFindings, AFile.FileName, xeAutomationFindingRequiresFormIDCompaction, 'warning', lRiskMessage);
    end;

    if lHasCellRisk then begin
      lRiskMessage := Format('%s contains new CELL records; compacting FormIDs can invalidate external references to placed content',
        [AFile.FileName]);
      xeAutomationAddFindingObject(Result.A['risks'], xeAutomationFindingNewCellRecordRisk, 'warning', lRiskMessage);
      xeAutomationAddPagedFinding(AFindings, AFile.FileName, xeAutomationFindingNewCellRecordRisk, 'warning', lRiskMessage);
    end;

    Result.B['eligible'] := (Result.A['blockers'].Count = 0) and not Result.B['requiresCompact'];
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationAnalyzePluginForEsl(const AFile: IwbFile; const AFindings: TJsonArray): TJsonObject;
var
  lNewRecordCount: Integer;
  lMaxObjectId, lMinObjectId: Cardinal;
  lHasCellRisk: Boolean;
  lSeenRecords: TDictionary<Cardinal, Boolean>;
begin
  lNewRecordCount := 0;
  lMaxObjectId := 0;
  lMinObjectId := 0;
  lHasCellRisk := False;
  lSeenRecords := TDictionary<Cardinal, Boolean>.Create;
  try
    xeAutomationCollectEslRecordStatsFromElement(AFile, AFile, lSeenRecords, lNewRecordCount, lMaxObjectId, lMinObjectId, lHasCellRisk);
    // The automation creation surface can leave fresh records in signature groups
    // before the file's shallow record view catches up. Probe all currently visible
    // top-level groups instead of baking a protocol-side signature allow-list into
    // analysis, then keep the ObjectID scan below as a fallback for tiny new files.
    xeAutomationCollectEslRecordStatsFromVisibleGroups(AFile, lSeenRecords, lNewRecordCount, lMaxObjectId, lMinObjectId,
      lHasCellRisk);
    // Unsaved new-file groups can also be visible through FormID lookup before
    // shallow record enumeration reflects them, so bounded ObjectID probing keeps
    // fresh automation fixtures and small plugins honest without scanning DLC scale.
    xeAutomationCollectEslRecordStatsByObjectIdScan(AFile, lSeenRecords, lNewRecordCount, lMaxObjectId, lMinObjectId, lHasCellRisk);
  finally
    lSeenRecords.Free;
  end;
  Result := xeAutomationDescribeEslStats(AFile, AFindings,
    lNewRecordCount, lMaxObjectId, lMinObjectId, lHasCellRisk);
end;

procedure xeAutomationSortMainRecordsByObjectId(var ARecords: TxeAutomationMainRecords);
var
  i: Integer;
  j: Integer;
  lTemp: IwbMainRecord;
begin
  for i := Low(ARecords) to High(ARecords) do
    for j := Succ(i) to High(ARecords) do
      if ARecords[j].LoadOrderFormID.ObjectID < ARecords[i].LoadOrderFormID.ObjectID then begin
        lTemp := ARecords[i];
        ARecords[i] := ARecords[j];
        ARecords[j] := lTemp;
      end;
end;

function xeAutomationPlanCompactForEsl(const AFile: IwbFile): TxeAutomationFormIdRemaps;
var
  lRecords: TxeAutomationMainRecords;
  lTakenObjectIds: array of Boolean;
  lLowestObjectId: Cardinal;
  lNextObjectId: Cardinal;
  lObjectId: Cardinal;
  lRecord: IwbMainRecord;
  i: Integer;
begin
  SetLength(Result, 0);
  lLowestObjectId := xeAutomationLightObjectIdLowest(AFile);

  SetLength(lTakenObjectIds, Succ(xeAutomationLightObjectIdLimit));
  lRecords := xeAutomationCollectNewMainRecordsInFile(AFile);
  xeAutomationSortMainRecordsByObjectId(lRecords);

  for lRecord in lRecords do begin
    lObjectId := lRecord.LoadOrderFormID.ObjectID;
    if (lObjectId >= lLowestObjectId) and (lObjectId <= xeAutomationLightObjectIdLimit) then
      lTakenObjectIds[lObjectId] := True;
  end;

  lNextObjectId := lLowestObjectId;
  for i := Low(lRecords) to High(lRecords) do begin
    lRecord := lRecords[i];
    lObjectId := lRecord.LoadOrderFormID.ObjectID;
    if (lObjectId >= lLowestObjectId) and (lObjectId <= xeAutomationLightObjectIdLimit) then
      Continue;

    while (lNextObjectId <= xeAutomationLightObjectIdLimit) and lTakenObjectIds[lNextObjectId] do
      Inc(lNextObjectId);
    if lNextObjectId > xeAutomationLightObjectIdLimit then
      raise xeAutomationNewError(xeAutomationErrorEligibilityFailed,
        Format('%s has too many new records to compact into the light ObjectID range', [AFile.FileName]));

    SetLength(Result, Succ(Length(Result)));
    Result[High(Result)].RecordRef := lRecord;
    Result[High(Result)].OldFormID := lRecord.LoadOrderFormID;
    Result[High(Result)].NewFormID := TwbFormID.FromCardinal(lNextObjectId).ChangeFileID(AFile.LoadOrderFileID);
    lTakenObjectIds[lNextObjectId] := True;
    Inc(lNextObjectId);
  end;
end;

procedure xeAutomationAddRemapFinding(const AFindings: TJsonArray; const AKind: string; const AFile: IwbFile;
  const ARemap: TxeAutomationFormIdRemap; const AApplied: Boolean);
var
  lFinding: TJsonObject;
begin
  lFinding := TJsonObject.Create;
  try
    lFinding.S['severity'] := 'info';
    if AApplied then
      lFinding.S['code'] := 'formid_remap_applied'
    else
      lFinding.S['code'] := 'formid_remap_planned';
    lFinding.S['message'] := Format('%s FormID remap in %s: %s -> %s',
      [xeAutomationAppliedWord(AApplied), AFile.FileName, ARemap.OldFormID.ToString(True), ARemap.NewFormID.ToString(True)]);
    lFinding.O['target'].S['file'] := AFile.FileName;
    lFinding.O['target'].S['formId'] := ARemap.OldFormID.ToString(True);
    lFinding.O['target'].S['signature'] := ARemap.RecordRef.Signature;
    lFinding.S['source'] := AKind;
    if AApplied then
      lFinding.O['action'].S['kind'] := 'applied'
    else
      lFinding.O['action'].S['kind'] := 'planned';
    lFinding.O['action'].S['oldFormId'] := ARemap.OldFormID.ToString(True);
    lFinding.O['action'].S['newFormId'] := ARemap.NewFormID.ToString(True);
    xeAutomationAppendJobFinding(AFindings, lFinding);
    lFinding := nil;
  finally
    lFinding.Free;
  end;
end;

function xeAutomationAddNonEditableReferrerFinding(const AFindings: TJsonArray; const AKind: string; const AFile: IwbFile;
  const ARemap: TxeAutomationFormIdRemap; const lReferrer: IwbMainRecord): Boolean;
var
  lFinding: TJsonObject;
begin
  Result := False;
    // External editable referrers are safe: the apply sweep rewrites them and
    // reports their files dirty. Only records/files xEdit cannot edit would keep
    // stale links after the target FormID is compacted.
    if Assigned(lReferrer) and ((not lReferrer.IsEditable) or (not lReferrer._File.IsEditable)) then begin
      Result := True;
      lFinding := TJsonObject.Create;
      try
        lFinding.S['severity'] := 'error';
        lFinding.S['code'] := xeAutomationFindingNonEditableReferrer;
        lFinding.S['message'] := Format('%s cannot compact %s because non-editable referrer %s:%s would retain %s',
          [AKind, ARemap.OldFormID.ToString(True), lReferrer._File.FileName, lReferrer.LoadOrderFormID.ToString(True),
           ARemap.OldFormID.ToString(True)]);
        lFinding.O['target'].S['file'] := AFile.FileName;
        lFinding.O['target'].S['formId'] := ARemap.OldFormID.ToString(True);
        lFinding.O['target'].S['newFormId'] := ARemap.NewFormID.ToString(True);
        lFinding.O['target'].S['signature'] := ARemap.RecordRef.Signature;
        lFinding.O['referrer'].S['file'] := lReferrer._File.FileName;
        lFinding.O['referrer'].S['formId'] := lReferrer.LoadOrderFormID.ToString(True);
        lFinding.O['referrer'].S['signature'] := lReferrer.Signature;
        lFinding.S['source'] := AKind;
        xeAutomationAppendJobFinding(AFindings, lFinding);
        lFinding := nil;
      finally
        lFinding.Free;
      end;
    end;
end;

function xeAutomationAddNonEditableReferrerFindings(const AFindings: TJsonArray; const AKind: string; const AFile: IwbFile;
  const ARemap: TxeAutomationFormIdRemap): Integer;
var masterRef: IwbMainRecord; i: Integer;
begin
  Result := 0;
  masterRef := ARemap.RecordRef.MasterOrSelf;
  for i := 0 to masterRef.ReferencedByCount - 1 do
    if xeAutomationAddNonEditableReferrerFinding(AFindings, AKind, AFile, ARemap, masterRef.ReferencedBy[i]) then Inc(Result);
end;

function xeAutomationAddNonEditableReferrerFindingsForBatch(const AFindings: TJsonArray; const AKind: string;
  const AFile: IwbFile; const ARemaps: TxeAutomationFormIdRemaps): Integer;
var
  lRemap: TxeAutomationFormIdRemap;
begin
  Result := 0;
  // Reference metadata is built immediately before this scan by the caller. Keeping
  // the policy as findings lets dry-run report stale-reference risk while apply mode
  // can fail before any FormID/header mutation is attempted.
  for lRemap in ARemaps do
    Inc(Result, xeAutomationAddNonEditableReferrerFindings(AFindings, AKind, AFile, lRemap));
end;

procedure xeAutomationBuildLoadedReferenceGraph;
var
  lModules: TwbModuleInfos;
  lFile: IwbFile;
  i: Integer;
begin
  // Referrers can live outside the compact target. Build references for every
  // loaded plugin so automation can fail on stale non-editable callers instead of
  // seeing only the target file's outgoing links.
  lModules := wbModulesByLoadOrder;
  for i := Low(lModules) to High(lModules) do begin
    lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
    if Assigned(lFile) then
      lFile.BuildOrLoadRef(False);
  end;
end;

procedure xeAutomationRequireWritableFormIdRemapTargets(const ARemap: TxeAutomationFormIdRemap);
var
  lMaster: IwbMainRecord;
  lRecord: IwbMainRecord;
  i: Integer;
begin
  xeAutomationRequireWritableEslMutationTarget(ARemap.RecordRef._File);

  for i := 0 to Pred(ARemap.RecordRef.OverrideCount) do begin
    lRecord := ARemap.RecordRef.Overrides[i];
    if Assigned(lRecord) then
      xeAutomationRequireWritableEslMutationTarget(lRecord._File);
  end;

  lMaster := ARemap.RecordRef.MasterOrSelf;
  for i := 0 to Pred(lMaster.ReferencedByCount) do begin
    lRecord := lMaster.ReferencedBy[i];
    if Assigned(lRecord) and lRecord.IsEditable then
      xeAutomationRequireWritableEslMutationTarget(lRecord._File);
  end;
end;

procedure xeAutomationRequireWritableFormIdRemapBatch(const ARemaps: TxeAutomationFormIdRemaps);
var
  lRemap: TxeAutomationFormIdRemap;
begin
  // Preflight every editable override/referrer before the first FormID assignment so
  // automation never partially compacts a target then discovers a non-target file is protected.
  for lRemap in ARemaps do
    xeAutomationRequireWritableFormIdRemapTargets(lRemap);
end;

procedure xeAutomationApplyFormIdRemap(const ARemap: TxeAutomationFormIdRemap; const ADirtyFiles: TJsonArray);
var
  lMaster: IwbMainRecord;
  lReferencedBy: TDynMainRecords;
  lOverrides: TDynMainRecords;
  i: Integer;
begin
  lMaster := ARemap.RecordRef.MasterOrSelf;
  SetLength(lReferencedBy, lMaster.ReferencedByCount);
  for i := 0 to Pred(lMaster.ReferencedByCount) do
    lReferencedBy[i] := lMaster.ReferencedBy[i];

  SetLength(lOverrides, ARemap.RecordRef.OverrideCount);
  for i := 0 to Pred(ARemap.RecordRef.OverrideCount) do
    lOverrides[i] := ARemap.RecordRef.Overrides[i];

  ARemap.RecordRef.LoadOrderFormID := ARemap.NewFormID;
  xeAutomationAddDirtyFile(ADirtyFiles, ARemap.RecordRef._File);
  for i := Low(lOverrides) to High(lOverrides) do
    if Assigned(lOverrides[i]) then begin
      lOverrides[i].LoadOrderFormID := ARemap.NewFormID;
      xeAutomationAddDirtyFile(ADirtyFiles, lOverrides[i]._File);
    end;

  // The GUI path prompts before touching referrers; automation has no dialog, so
  // it applies the same native CompareExchange sweep deterministically in memory
  // and reports every file where that sweep actually changed a reference.
  for i := Low(lReferencedBy) to High(lReferencedBy) do
    if Assigned(lReferencedBy[i]) and lReferencedBy[i].IsEditable then
      if lReferencedBy[i].CompareExchangeFormID(ARemap.OldFormID, ARemap.NewFormID) then
        xeAutomationAddDirtyFile(ADirtyFiles, lReferencedBy[i]._File);
end;

procedure xeAutomationUpdateNextObjectIdAfterCompact(const AFile: IwbFile);
var
  lRecords: TxeAutomationMainRecords;
  lRecord: IwbMainRecord;
  lMaxObjectId: Cardinal;
begin
  lMaxObjectId := 0;
  lRecords := xeAutomationCollectNewMainRecordsInFile(AFile);
  for lRecord in lRecords do
    if lRecord.LoadOrderFormID.ObjectID > lMaxObjectId then
      lMaxObjectId := lRecord.LoadOrderFormID.ObjectID;
  if lMaxObjectId < xeAutomationLightObjectIdLimit then
    AFile.NextObjectID := Succ(lMaxObjectId)
  else
    AFile.NextObjectID := xeAutomationLightObjectIdLimit;
end;

procedure xeAutomationWriteCompactResultFile(const ATarget: TJsonArray; const AFile: IwbFile;
  const ARemaps: TxeAutomationFormIdRemaps; const AApplied: Boolean);
var
  lFileResult: TJsonObject;
  lRemapObject: TJsonObject;
  lRemap: TxeAutomationFormIdRemap;
begin
  lFileResult := TJsonObject.Create;
  try
    lFileResult.S['fileName'] := AFile.FileName;
    lFileResult.B['changed'] := AApplied and (Length(ARemaps) > 0);
    lFileResult.I['remapCount'] := Length(ARemaps);
    lFileResult.B['eslFlagChanged'] := False;
    lFileResult.B['isLight'] := AFile.IsLight;
    for lRemap in ARemaps do begin
      lRemapObject := TJsonObject.Create;
      try
        lRemapObject.S['file'] := AFile.FileName;
        lRemapObject.S['signature'] := lRemap.RecordRef.Signature;
        lRemapObject.S['oldFormId'] := lRemap.OldFormID.ToString(True);
        lRemapObject.S['newFormId'] := lRemap.NewFormID.ToString(True);
        lFileResult.A['remaps'].Add(lRemapObject);
        lRemapObject := nil;
      finally
        lRemapObject.Free;
      end;
    end;
    ATarget.Add(lFileResult);
    lFileResult := nil;
  finally
    lFileResult.Free;
  end;
end;

procedure xeAutomationPluginFormIdsCompactForEslJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
var
  lFiles: TJsonArray;
  lFile: IwbFile;
  lRemaps: TxeAutomationFormIdRemaps;
  lFileName: string;
  i: Integer;
  lRemap: TxeAutomationFormIdRemap;
begin
  lFiles := ATarget.A['files'];
  ASummary.I['targets'] := lFiles.Count;
  ASummary.I['planned'] := 0;
  ASummary.I['applied'] := 0;
  ASummary.I['findings'] := 0;
  ASummary.B['changed'] := False;
  ASummary.B['requiresSave'] := False;
  ASummary.A['dirtyFiles'].Clear;
  AResult.A['files'].Clear;

  for i := 0 to Pred(lFiles.Count) do begin
    lFileName := Trim(lFiles.S[i]);
    lFile := xeAutomationRequirePluginFile(lFileName);
    if not ADryRun then
      // Apply mode mutates FormIDs only in the loaded xEdit session. The explicit
      // save boundary is preserved by not calling any disk-writing file routines.
      xeAutomationRequireWritableEslMutationTarget(lFile);
    lRemaps := xeAutomationPlanCompactForEsl(lFile);
    if Length(lRemaps) > 0 then begin
      xeAutomationBuildLoadedReferenceGraph;
      if xeAutomationAddNonEditableReferrerFindingsForBatch(AFindings, xeAutomationFormIdsCompactForEslKind, lFile, lRemaps) > 0 then
        if not ADryRun then
          raise xeAutomationNewError(xeAutomationFindingNonEditableReferrer,
            Format('%s has non-editable referrers that would remain stale after FormID compaction', [lFile.FileName]));
    end;
    if not ADryRun then
      xeAutomationRequireWritableFormIdRemapBatch(lRemaps);

    for lRemap in lRemaps do begin
      xeAutomationAddRemapFinding(AFindings, xeAutomationFormIdsCompactForEslKind, lFile, lRemap, not ADryRun);
      if ADryRun then
        ASummary.I['planned'] := ASummary.I['planned'] + 1
      else begin
        lFile.BuildOrLoadRef(False);
        xeAutomationApplyFormIdRemap(lRemap, ASummary.A['dirtyFiles']);
        ASummary.I['applied'] := ASummary.I['applied'] + 1;
      end;
    end;

    if not ADryRun and (Length(lRemaps) > 0) then begin
      xeAutomationUpdateNextObjectIdAfterCompact(lFile);
      ASummary.B['changed'] := True;
      ASummary.B['requiresSave'] := True;
      xeAutomationAddDirtyFile(ASummary.A['dirtyFiles'], lFile);
    end;
    xeAutomationWriteCompactResultFile(AResult.A['files'], lFile, lRemaps, not ADryRun);
  end;

  ASummary.I['findings'] := AFindings.Count;
end;

procedure xeAutomationAddEslApplyFinding(const AFindings: TJsonArray; const AFile: IwbFile; const AOldESL, ANewESL: Boolean;
  const AApplied: Boolean);
var
  lFinding: TJsonObject;
begin
  lFinding := TJsonObject.Create;
  try
    lFinding.S['severity'] := 'info';
    if AApplied then
      lFinding.S['code'] := 'esl_flag_applied'
    else
      lFinding.S['code'] := 'esl_flag_planned';
    lFinding.S['message'] := Format('%s ESL header flag for %s: %s -> %s',
      [xeAutomationAppliedWord(AApplied), AFile.FileName, BoolToStr(AOldESL, True), BoolToStr(ANewESL, True)]);
    lFinding.O['target'].S['file'] := AFile.FileName;
    lFinding.S['source'] := xeAutomationEslApplyKind;
    if AApplied then
      lFinding.O['action'].S['kind'] := 'applied'
    else
      lFinding.O['action'].S['kind'] := 'planned';
    lFinding.O['action'].B['oldEsl'] := AOldESL;
    lFinding.O['action'].B['newEsl'] := ANewESL;
    xeAutomationAppendJobFinding(AFindings, lFinding);
    lFinding := nil;
  finally
    lFinding.Free;
  end;
end;

function xeAutomationEnsureEslApplyEligibility(const AFile: IwbFile; const AAllowAfterCompact: Boolean; const AFindings: TJsonArray): Boolean;
var
  lAnalysis: TJsonObject;
  lBlockerCount: Integer;
begin
  Result := False;
  lAnalysis := xeAutomationAnalyzePluginForEsl(AFile, AFindings);
  try
    lBlockerCount := lAnalysis.A['blockers'].Count;
    if lAnalysis.B['eligible'] then
      Exit;
    if AAllowAfterCompact and (lBlockerCount = 0) and lAnalysis.B['requiresCompact'] then begin
      Result := True;
      Exit;
    end;
    raise xeAutomationNewError(xeAutomationErrorEligibilityFailed,
      Format('%s is not currently eligible for ESL flag application', [AFile.FileName]));
  finally
    lAnalysis.Free;
  end;
end;

procedure xeAutomationWriteEslApplyResultFile(const ATarget: TJsonArray; const AFile: IwbFile;
  const AOldFlags, ANewFlags: TJsonObject; const ARemaps: TxeAutomationFormIdRemaps; const ACompacted: Boolean; const AChanged: Boolean);
var
  lFileResult: TJsonObject;
  lRemapObject: TJsonObject;
  lRemap: TxeAutomationFormIdRemap;
begin
  lFileResult := TJsonObject.Create;
  try
    lFileResult.S['fileName'] := AFile.FileName;
    lFileResult.O['oldFlags'].Assign(AOldFlags);
    lFileResult.O['newFlags'].Assign(ANewFlags);
    lFileResult.B['compacted'] := ACompacted;
    lFileResult.I['remapCount'] := Length(ARemaps);
    for lRemap in ARemaps do begin
      lRemapObject := TJsonObject.Create;
      try
        lRemapObject.S['file'] := AFile.FileName;
        lRemapObject.S['signature'] := lRemap.RecordRef.Signature;
        lRemapObject.S['oldFormId'] := lRemap.OldFormID.ToString(True);
        lRemapObject.S['newFormId'] := lRemap.NewFormID.ToString(True);
        lFileResult.A['remaps'].Add(lRemapObject);
        lRemapObject := nil;
      finally
        lRemapObject.Free;
      end;
    end;
    lFileResult.B['changed'] := AChanged;
    ATarget.Add(lFileResult);
    lFileResult := nil;
  finally
    lFileResult.Free;
  end;
end;

procedure xeAutomationPluginEslApplyJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
var
  lFiles: TJsonArray;
  lFile: IwbFile;
  lAllowAfterCompact: Boolean;
  lOldFlags: TJsonObject;
  lNewFlags: TJsonObject;
  lRemaps: TxeAutomationFormIdRemaps;
  lRemap: TxeAutomationFormIdRemap;
  lRequiresCompact: Boolean;
  lChanged: Boolean;
  i: Integer;
begin
  lFiles := ATarget.A['files'];
  lAllowAfterCompact := xeAutomationReadBooleanOption(AOptions, 'allowAfterCompact', False);
  ASummary.I['targets'] := lFiles.Count;
  ASummary.I['planned'] := 0;
  ASummary.I['applied'] := 0;
  ASummary.I['findings'] := 0;
  ASummary.B['changed'] := False;
  ASummary.B['requiresSave'] := False;
  ASummary.A['dirtyFiles'].Clear;
  AResult.A['files'].Clear;

  for i := 0 to Pred(lFiles.Count) do begin
    lFile := xeAutomationRequirePluginFile(Trim(lFiles.S[i]));
    if not ADryRun then
      // ESL apply may optionally compact first, but both mutations still stay in
      // daemon memory; session.save remains the only disk persistence boundary.
      xeAutomationRequireWritableEslMutationTarget(lFile);
    lRequiresCompact := xeAutomationEnsureEslApplyEligibility(lFile, lAllowAfterCompact, AFindings);
    SetLength(lRemaps, 0);
    if lRequiresCompact then begin
      lRemaps := xeAutomationPlanCompactForEsl(lFile);
      if Length(lRemaps) > 0 then begin
        xeAutomationBuildLoadedReferenceGraph;
        if xeAutomationAddNonEditableReferrerFindingsForBatch(AFindings, xeAutomationEslApplyKind, lFile, lRemaps) > 0 then
          if not ADryRun then
            raise xeAutomationNewError(xeAutomationFindingNonEditableReferrer,
              Format('%s has non-editable referrers that would remain stale after FormID compaction', [lFile.FileName]));
      end;
      if not ADryRun then begin
        xeAutomationRequireWritableFormIdRemapBatch(lRemaps);
        for lRemap in lRemaps do begin
          xeAutomationApplyFormIdRemap(lRemap, ASummary.A['dirtyFiles']);
          xeAutomationAddRemapFinding(AFindings, xeAutomationEslApplyKind, lFile, lRemap, True);
        end;
        if Length(lRemaps) > 0 then begin
          xeAutomationUpdateNextObjectIdAfterCompact(lFile);
          ASummary.B['changed'] := True;
          ASummary.B['requiresSave'] := True;
          xeAutomationAddDirtyFile(ASummary.A['dirtyFiles'], lFile);
        end;
      end else
        for lRemap in lRemaps do
          xeAutomationAddRemapFinding(AFindings, xeAutomationEslApplyKind, lFile, lRemap, False);
    end;

    lOldFlags := xeAutomationNewHeaderFlags(lFile);
    try
      if not ADryRun and not lFile.IsLight then
        lFile.IsLight := True;
      lNewFlags := xeAutomationNewHeaderFlags(lFile);
      try
        if ADryRun then
          lNewFlags.B['esl'] := True;
        lChanged := lOldFlags.B['esl'] <> lNewFlags.B['esl'];
        xeAutomationAddEslApplyFinding(AFindings, lFile, lOldFlags.B['esl'], lNewFlags.B['esl'], not ADryRun);
        if ADryRun then
          ASummary.I['planned'] := ASummary.I['planned'] + 1
        else if lChanged then begin
          ASummary.I['applied'] := ASummary.I['applied'] + 1;
          ASummary.B['changed'] := True;
          ASummary.B['requiresSave'] := True;
          xeAutomationAddDirtyFile(ASummary.A['dirtyFiles'], lFile);
        end;
        xeAutomationWriteEslApplyResultFile(AResult.A['files'], lFile, lOldFlags, lNewFlags, lRemaps, lRequiresCompact and not ADryRun,
          lChanged or (not ADryRun and (Length(lRemaps) > 0)));
      finally
        lNewFlags.Free;
      end;
    finally
      lOldFlags.Free;
    end;
  end;

  ASummary.I['findings'] := AFindings.Count;
end;

procedure xeAutomationPluginEslAnalyzeJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
var
  lFiles: TJsonArray;
  lFile: IwbFile;
  lAnalysis: TJsonObject;
  i: Integer;
begin
  lFiles := ATarget.A['files'];
  ASummary.I['targets'] := lFiles.Count;
  ASummary.I['eligible'] := 0;
  ASummary.I['ineligible'] := 0;
  ASummary.I['findings'] := 0;
  ASummary.B['changed'] := False;
  ASummary.B['requiresSave'] := False;
  ASummary.A['dirtyFiles'].Clear;
  AResult.A['files'].Clear;

  for i := 0 to Pred(lFiles.Count) do begin
    // File lookup is the execution boundary: malformed target shape was rejected at
    // jobs.start, while absent loaded files remain normal job execution failures.
    lFile := xeAutomationRequirePluginFile(Trim(lFiles.S[i]));
    lAnalysis := xeAutomationAnalyzePluginForEsl(lFile, AFindings);
    try
      if lAnalysis.B['eligible'] then
        ASummary.I['eligible'] := ASummary.I['eligible'] + 1
      else
        ASummary.I['ineligible'] := ASummary.I['ineligible'] + 1;
      AResult.A['files'].Add(lAnalysis);
      lAnalysis := nil;
    finally
      lAnalysis.Free;
    end;
  end;

  ASummary.I['findings'] := AFindings.Count;
end;

type
  TEslScanPhase = (espTree, espGroups, espObjectIds, espReport, espComplete);
  TEslScanFrame = class
  public
    Element: IwbElement;
    Container: IwbContainer;
    NextChild: Integer;
    Entered: Boolean;
    constructor Create(const elementRef: IwbElement);
  end;
  TEslAnalysisStepper = class(TxeAutomationJobStepper)
  private
    FFileName: string;
    FFile: IwbFile;
    FRow: TJsonObject;
    FStack: TObjectList<TEslScanFrame>;
    FSeen: TDictionary<Cardinal, Boolean>;
    FPhase: TEslScanPhase;
    FNewCount, FGroupIndex, FWork, FLastWork, FSteps: Integer;
    FMin, FMax, FObjectId, FObjectIdLimit: Cardinal;
    FHasCellRisk: Boolean;
    procedure Push(const elementRef: IwbElement);
    procedure Observe(const recordRef: IwbMainRecord);
    procedure WalkOne;
    procedure GroupOne;
    procedure ObjectIdOne;
  public
    constructor Create(const fileName: string);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TEslScanFrame.Create(const elementRef: IwbElement);
begin inherited Create; Element := elementRef; end;
constructor TEslAnalysisStepper.Create(const fileName: string);
begin
  inherited Create; FFileName := fileName;
  FStack := TObjectList<TEslScanFrame>.Create(True);
  FSeen := TDictionary<Cardinal, Boolean>.Create;
end;
destructor TEslAnalysisStepper.Destroy;
begin FStack.Free; FSeen.Free; FFile := nil; inherited; end;

procedure TEslAnalysisStepper.Push(const elementRef: IwbElement);
begin
  if FStack.Count >= xeAutomationJobStepDepthLimit then
    raise xeAutomationNewError('job_capacity', 'ESL analysis traversal exceeds depth64');
  FStack.Add(TEslScanFrame.Create(elementRef));
end;

procedure TEslAnalysisStepper.Observe(const recordRef: IwbMainRecord);
begin
  if Assigned(recordRef) and (recordRef <> FFile.Header) and
     (recordRef.LoadOrderFormID.FileID = FFile.LoadOrderFileID) and
     not FSeen.ContainsKey(recordRef.LoadOrderFormID.ToCardinal) and
     (FSeen.Count >= xeAutomationEslScanRecordLimit) then
    raise xeAutomationNewError('job_capacity', 'ESL analysis retains at most100000 new record IDs');
  // Retain the same header exclusion, ownership predicate and identity dedup.
  xeAutomationAddEslRecordStats(FFile, recordRef, FSeen, FNewCount, FMax, FMin, FHasCellRisk);
end;

procedure TEslAnalysisStepper.WalkOne;
var frame: TEslScanFrame; recordRef: IwbMainRecord; elementRef: IwbElement;
begin
  if FStack.Count = 0 then begin
    if FPhase = espTree then FPhase := espGroups else FPhase := espObjectIds;
    Exit;
  end;
  frame := FStack.Last;
  if not frame.Entered then begin
    frame.Entered := True;
    if Supports(frame.Element, IwbMainRecord, recordRef) then Observe(recordRef);
    Supports(frame.Element, IwbContainer, frame.Container);
  end else if Assigned(frame.Container) and (frame.NextChild < frame.Container.ElementCount) then begin
    elementRef := frame.Container.Elements[frame.NextChild];
    Inc(frame.NextChild);
    Push(elementRef);
  end else FStack.Delete(FStack.Count - 1);
end;

procedure TEslAnalysisStepper.GroupOne;
var containerRef: IwbContainer; groupRef: IwbGroupRecord;
begin
  if FStack.Count > 0 then begin WalkOne; Exit; end;
  if Supports(FFile, IwbContainer, containerRef) and (FGroupIndex < containerRef.ElementCount) then begin
    if Supports(containerRef.Elements[FGroupIndex], IwbGroupRecord, groupRef) then Push(groupRef);
    Inc(FGroupIndex);
  end else begin
    // Preserve the legacy timing: HighObjectID is read after both tree passes.
    FObjectIdLimit := FFile.HighObjectID;
    if FObjectIdLimit > $FFFF then FObjectIdLimit := 0;
    FPhase := espObjectIds;
  end;
end;

procedure TEslAnalysisStepper.ObjectIdOne;
var identity: TwbFormID;
begin
  if FObjectId > FObjectIdLimit then begin FPhase := espReport; Exit; end;
  identity := TwbFormID.FromCardinal(FObjectId).ChangeFileID(FFile.LoadOrderFileID);
  Observe(FFile.RecordByFormID[identity, True, True]);
  Inc(FObjectId);
end;

function TEslAnalysisStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var timer: TStopwatch; descriptor: TJsonObject;
begin
  Inc(FSteps); FLastWork := 0; timer := TStopwatch.StartNew;
  try
    if not Assigned(FFile) then begin
      FFile := xeAutomationRequirePluginFile(Trim(FFileName));
      FObjectId := 1;
      FRow := resultData.A['files'].AddObject;
      FRow.S['fileName'] := FFile.FileName;
      FRow.B['complete'] := False; FRow.B['statsComplete'] := False;
      summary.I['targets'] := summary.I['targets'] + 1;
      summary.B['changed'] := False; summary.B['requiresSave'] := False;
      summary.S['persistence'] := 'read-only; no plugin save';
      Push(FFile);
      Inc(FLastWork);
    end;
    while (FPhase <> espComplete) and (FLastWork < xeAutomationJobStepWorkLimit) and
          (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
      if FWork >= xeAutomationEslScanWorkLimit then
        raise xeAutomationNewError('job_capacity', 'ESL analysis exceeds1000000 work units');
      Inc(FWork); Inc(FLastWork);
      case FPhase of
        espTree: WalkOne;
        espGroups: GroupOne;
        espObjectIds: ObjectIdOne;
        espReport: begin
          descriptor := xeAutomationDescribeEslStats(FFile, findings, FNewCount, FMax, FMin, FHasCellRisk);
          try
            FRow.Assign(descriptor);
            FRow.B['complete'] := True; FRow.B['statsComplete'] := True;
            if FRow.B['eligible'] then summary.I['eligible'] := summary.I['eligible'] + 1
            else summary.I['ineligible'] := summary.I['ineligible'] + 1;
          finally descriptor.Free; end;
          FPhase := espComplete;
        end;
      end;
    end;
  finally
    summary.I['findings'] := findings.Count;
    if Assigned(FRow) and not FRow.B['complete'] then begin
      FRow.I['newRecordCount'] := FNewCount;
      FRow.S['minObjectId'] := xeAutomationObjectIdHex(FMin);
      FRow.S['maxObjectId'] := xeAutomationObjectIdHex(FMax);
      FRow.B['hasCellRiskObserved'] := FHasCellRisk;
      FRow.B['statsComplete'] := FPhase in [espReport, espComplete];
    end;
  end;
  Result := FPhase = espComplete;
end;

procedure TEslAnalysisStepper.WriteProgress(const progress: TJsonObject);
const phases: array[TEslScanPhase] of string = ('file-tree', 'visible-groups', 'object-id-fallback', 'report', 'complete');
begin
  progress.S['fileName'] := FFileName; progress.S['phase'] := phases[FPhase];
  progress.I['steps'] := FSteps; progress.I['lastWorkUnits'] := FLastWork;
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  progress.I['totalWorkUnits'] := FWork; progress.I['totalWorkLimit'] := xeAutomationEslScanWorkLimit;
  progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.I['retainedDepth'] := FStack.Count; progress.I['depthLimit'] := xeAutomationJobStepDepthLimit;
  progress.I['newRecordCount'] := FNewCount; progress.I['seenRecordLimit'] := xeAutomationEslScanRecordLimit;
  if FObjectId > 0 then progress.I['objectIdProbes'] := Integer(FObjectId) - 1
  else progress.I['objectIdProbes'] := 0;
  progress.I['objectIdProbeLimit'] := FObjectIdLimit;
  progress.B['nativeCallsPreemptible'] := False;
  progress.S['nativeAtoms'] := 'container initialization/access; native HighObjectID sorting; one native FormID lookup; final eligibility getters';
end;

function NewEslAnalysisStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin Result := TEslAnalysisStepper.Create(target.A['files'].S[0]); end;

type
  TCompactPhase = (cspTree, cspRecords, cspSort, cspReserve, cspPlan,
    cspReferences, cspPreflight, cspApply, cspHeader, cspComplete);
  TCompactStepper = class(TxeAutomationJobStepper)
  private
    FName, FKind: string;
    FDry: Boolean;
    FRefreshReferences: Boolean;
    FExternalRow: TJsonObject;
    FFile: IwbFile;
    FRow: TJsonObject;
    FSnapshot: TxeAutomationMutationSnapshot;
    FStack: TObjectList<TEslScanFrame>;
    FSeen: TDictionary<Cardinal, Boolean>;
    FRecords, FScratch: TxeAutomationMainRecords;
    FRemaps: TxeAutomationFormIdRemaps;
    FModules: TwbModuleInfos;
    FTaken: array[0..$FFF] of Boolean;
    FPhase: TCompactPhase;
    FCount, FIndex, FRecordLimit, FWork, FLastWork, FSteps, FApplied: Integer;
    FWidth, FStart, FLeft, FMiddle, FRight, FEnd, FOutput: Integer;
    FModuleIndex, FOverrideIndex, FReferrerIndex, FBlockers: Integer;
    FOverrideCount, FReferrerCount: Integer;
    FEdgesReady: Boolean;
    FLowest, FNext, FMaxAfter: Cardinal;
    procedure Observe(const recordRef: IwbMainRecord);
    procedure WalkOne;
    procedure SortOne;
    procedure PlanOne;
    procedure PreflightOne(const findings: TJsonArray);
    procedure UpdateAudit(const summary: TJsonObject);
  public
    constructor Create(const name, kind: string; const dry, refreshReferences: Boolean;
      const externalRow: TJsonObject = nil);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TCompactStepper.Create(const name, kind: string; const dry, refreshReferences: Boolean;
  const externalRow: TJsonObject);
begin
  inherited Create; FName := name; FKind := kind; FDry := dry;
  FRefreshReferences := refreshReferences; FExternalRow := externalRow;
  FStack := TObjectList<TEslScanFrame>.Create(True);
  FSeen := TDictionary<Cardinal, Boolean>.Create;
end;

destructor TCompactStepper.Destroy;
begin
  FStack.Free; FSeen.Free;
  FRecords := nil; FScratch := nil; FRemaps := nil;
  FSnapshot.Files := nil; FModules := nil; FFile := nil;
  inherited;
end;

procedure TCompactStepper.Observe(const recordRef: IwbMainRecord);
var identity: Cardinal;
begin
  if not Assigned(recordRef) or (recordRef = FFile.Header) or
     (recordRef.LoadOrderFormID.FileID <> FFile.LoadOrderFileID) then Exit;
  identity := recordRef.LoadOrderFormID.ToCardinal;
  if FSeen.ContainsKey(identity) then Exit;
  if FCount >= Integer(xeAutomationLightObjectIdCapacity(FFile)) then
    raise xeAutomationNewError(xeAutomationErrorEligibilityFailed,
      'Too many new records to compact into the light ObjectID range');
  FSeen.Add(identity, True); FRecords[FCount] := recordRef; Inc(FCount);
end;

procedure TCompactStepper.WalkOne;
var frame: TEslScanFrame; recordRef: IwbMainRecord; child: IwbElement;
begin
  if FStack.Count = 0 then begin
    FRecordLimit := FFile.RecordCount; FPhase := cspRecords; Exit;
  end;
  frame := FStack.Last;
  if not frame.Entered then begin
    frame.Entered := True;
    if Supports(frame.Element, IwbMainRecord, recordRef) then Observe(recordRef);
    Supports(frame.Element, IwbContainer, frame.Container);
  end else if Assigned(frame.Container) and (frame.NextChild < frame.Container.ElementCount) then begin
    if FStack.Count >= xeAutomationJobStepDepthLimit then
      raise xeAutomationNewError('job_capacity', 'Compaction tree exceeds depth64');
    child := frame.Container.Elements[frame.NextChild]; Inc(frame.NextChild);
    FStack.Add(TEslScanFrame.Create(child));
  end else FStack.Delete(FStack.Count - 1);
end;

procedure TCompactStepper.SortOne;
var temp: TxeAutomationMainRecords;
begin
  // Bottom-up merge sort: one interface assignment/compare per work unit.
  if FWidth >= FCount then begin FIndex := 0; FPhase := cspReserve; Exit; end;
  if FStart >= FCount then begin
    temp := FRecords; FRecords := FScratch; FScratch := temp;
    FWidth := FWidth * 2; FStart := 0; FOutput := 0; Exit;
  end;
  if FOutput = FStart then begin
    FLeft := FStart; FMiddle := FStart + FWidth;
    if FMiddle > FCount then FMiddle := FCount;
    FRight := FMiddle; FEnd := FStart + 2 * FWidth;
    if FEnd > FCount then FEnd := FCount;
  end;
  if (FLeft < FMiddle) and ((FRight >= FEnd) or
     (FRecords[FLeft].LoadOrderFormID.ObjectID <= FRecords[FRight].LoadOrderFormID.ObjectID)) then begin
    FScratch[FOutput] := FRecords[FLeft]; Inc(FLeft);
  end else begin FScratch[FOutput] := FRecords[FRight]; Inc(FRight); end;
  Inc(FOutput);
  if FOutput >= FEnd then FStart := FEnd;
end;

procedure TCompactStepper.PlanOne;
var recordRef: IwbMainRecord; objectId: Cardinal; remapRow: TJsonObject; n: Integer;
begin
  if FIndex >= FCount then begin
    FRow.B['planningComplete'] := True;
    FModules := wbModulesByLoadOrder; FIndex := 0;
    if Length(FRemaps) > 0 then FPhase := cspReferences
    else begin FRow.B['preflightComplete'] := True; FPhase := cspHeader; end;
    Exit;
  end;
  recordRef := FRecords[FIndex]; objectId := recordRef.LoadOrderFormID.ObjectID;
  if (objectId >= FLowest) and (objectId <= xeAutomationLightObjectIdLimit) then begin Inc(FIndex); Exit; end;
  if FNext > xeAutomationLightObjectIdLimit then
    raise xeAutomationNewError(xeAutomationErrorEligibilityFailed, 'No free light ObjectID for compaction');
  if FTaken[FNext] then begin Inc(FNext); Exit; end;
  n := Length(FRemaps); SetLength(FRemaps, n + 1);
  FRemaps[n].RecordRef := recordRef;
  FRemaps[n].OldFormID := recordRef.LoadOrderFormID;
  FRemaps[n].NewFormID := TwbFormID.FromCardinal(FNext).ChangeFileID(FFile.LoadOrderFileID);
  FTaken[FNext] := True;
  if FNext > FMaxAfter then FMaxAfter := FNext;
  remapRow := FRow.A['remaps'].AddObject;
  remapRow.S['file'] := FFile.FileName; remapRow.S['signature'] := recordRef.Signature;
  remapRow.S['oldFormId'] := FRemaps[n].OldFormID.ToString(True);
  remapRow.S['newFormId'] := FRemaps[n].NewFormID.ToString(True);
  remapRow.S['outcome'] := 'not_started';
  Inc(FNext); Inc(FIndex);
end;

procedure TCompactStepper.PreflightOne(const findings: TJsonArray);
var remap: TxeAutomationFormIdRemap; recordRef, masterRef: IwbMainRecord;
begin
  if FIndex >= Length(FRemaps) then begin
    if (FBlockers > 0) and not FDry then
      raise xeAutomationNewError(xeAutomationFindingNonEditableReferrer,
        'Non-editable referrers would retain stale FormIDs after compaction');
    FRow.B['preflightComplete'] := True; FIndex := 0; FPhase := cspApply; Exit;
  end;
  remap := FRemaps[FIndex]; masterRef := remap.RecordRef.MasterOrSelf;
  if not FEdgesReady then begin
    if not FDry then xeAutomationRequireWritableEslMutationTarget(remap.RecordRef._File);
    FOverrideCount := remap.RecordRef.OverrideCount; FReferrerCount := masterRef.ReferencedByCount;
    if (FOverrideCount > xeAutomationCompactEdgeLimit) or (FReferrerCount > xeAutomationCompactEdgeLimit) then
      raise xeAutomationNewError('job_capacity', 'A native remap retains at most100000 overrides and100000 referrers');
    FOverrideIndex := 0; FReferrerIndex := 0; FEdgesReady := True; Exit;
  end;
  if FOverrideIndex < FOverrideCount then begin
    recordRef := remap.RecordRef.Overrides[FOverrideIndex]; Inc(FOverrideIndex);
    if Assigned(recordRef) and not FDry then xeAutomationRequireWritableEslMutationTarget(recordRef._File);
  end else if FReferrerIndex < FReferrerCount then begin
    recordRef := masterRef.ReferencedBy[FReferrerIndex]; Inc(FReferrerIndex);
    if xeAutomationAddNonEditableReferrerFinding(findings, FKind,
      FFile, remap, recordRef) then Inc(FBlockers);
    if Assigned(recordRef) and recordRef.IsEditable and not FDry then
      xeAutomationRequireWritableEslMutationTarget(recordRef._File);
  end else begin Inc(FIndex); FEdgesReady := False; end;
end;

procedure TCompactStepper.UpdateAudit(const summary: TJsonObject);
var i: Integer; fileRef: IwbFile; needsSave: Boolean;
begin
  xeAutomationWriteMutationAudit(FRow.O['mutationState'], FSnapshot);
  FRow.B['changed'] := FRow.O['mutationState'].B['mutationsObserved'];
  summary.B['changed'] := summary.B['changed'] or FRow.B['changed'];
  needsSave := False;
  for i := 0 to Length(FSnapshot.Files) - 1 do begin
    fileRef := FSnapshot.Files[i].FileRef;
    if fileRef.Modified and ((fileRef = FFile) or
       (fileRef.ElementGeneration <> FSnapshot.Files[i].Generation)) then begin
      xeAutomationAddDirtyFile(summary.A['dirtyFiles'], fileRef);
      needsSave := True;
    end;
  end;
  FRow.B['requiresSave'] := needsSave;
  summary.B['requiresSave'] := summary.B['requiresSave'] or needsSave;
end;

function TCompactStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var timer: TStopwatch; oldPhase: TCompactPhase; fileRef: IwbFile;
    objectId: Cardinal; remap: TxeAutomationFormIdRemap;
begin
  Inc(FSteps); FLastWork := 0; timer := TStopwatch.StartNew;
  try
    if not Assigned(FFile) then begin
      FFile := xeAutomationRequirePluginFile(FName);
      if not FDry then xeAutomationRequireWritableEslMutationTarget(FFile);
      FSnapshot := xeAutomationCaptureMutationSnapshot;
      if Assigned(FExternalRow) then FRow := FExternalRow
      else FRow := resultData.A['files'].AddObject;
      FRow.S['fileName'] := FFile.FileName;
      FRow.B['complete'] := False; FRow.B['planningComplete'] := False; FRow.B['preflightComplete'] := False;
      FRow.B['eslFlagChanged'] := False; FRow.B['isLight'] := FFile.IsLight;
      FLowest := xeAutomationLightObjectIdLowest(FFile); FNext := FLowest;
      SetLength(FRecords, xeAutomationLightObjectIdCapacity(FFile));
      FStack.Add(TEslScanFrame.Create(FFile));
      summary.I['targets'] := summary.I['targets'] + 1;
      // Retain the legacy counter shape even before either branch has work.
      if not summary.Contains('planned') then summary.I['planned'] := 0;
      if not summary.Contains('applied') then summary.I['applied'] := 0;
      summary.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush';
      Inc(FLastWork);
    end;
    while (FPhase <> cspComplete) and (FLastWork < xeAutomationJobStepWorkLimit) and
      (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
      if FWork >= xeAutomationEslScanWorkLimit then
        raise xeAutomationNewError('job_capacity', 'Compaction exceeds1000000 work units');
      Inc(FWork); Inc(FLastWork); oldPhase := FPhase;
      case FPhase of
        cspTree: WalkOne;
        cspRecords: if FIndex < FRecordLimit then begin
          Observe(FFile.Records[FIndex]); Inc(FIndex);
        end else begin
          SetLength(FRecords, FCount); SetLength(FScratch, FCount);
          FWidth := 1; FPhase := cspSort;
        end;
        cspSort: SortOne;
        cspReserve: if FIndex < FCount then begin
          objectId := FRecords[FIndex].LoadOrderFormID.ObjectID;
          if (objectId >= FLowest) and (objectId <= xeAutomationLightObjectIdLimit) then begin
            FTaken[objectId] := True;
            if objectId > FMaxAfter then FMaxAfter := objectId;
          end;
          Inc(FIndex);
        end else begin FIndex := 0; FPhase := cspPlan; end;
        cspPlan: PlanOne;
        cspReferences: if FModuleIndex < Length(FModules) then begin
          fileRef := xeAutomationTryPluginFileFromModule(FModules[FModuleIndex]); Inc(FModuleIndex);
          if Assigned(fileRef) then fileRef.BuildOrLoadRef(False);
        end else begin FIndex := 0; FPhase := cspPreflight; end;
        cspPreflight: PreflightOne(findings);
        cspApply: if FIndex < Length(FRemaps) then begin
          remap := FRemaps[FIndex];
          if FDry then begin
            FRow.A['remaps'].O[FIndex].S['outcome'] := 'planned';
            summary.I['planned'] := summary.I['planned'] + 1;
          end else begin
            xeAutomationRequireWritableEslMutationTarget(FFile);
            if remap.RecordRef.LoadOrderFormID <> remap.OldFormID then
              raise xeAutomationNewError('job_state_changed', 'Planned FormID changed before remap');
            // Preserve the standalone route's native reference refresh before each remap.
            if FRefreshReferences then FFile.BuildOrLoadRef(False);
            if (remap.RecordRef.OverrideCount > xeAutomationCompactEdgeLimit) or
               (remap.RecordRef.MasterOrSelf.ReferencedByCount > xeAutomationCompactEdgeLimit) then
              raise xeAutomationNewError('job_capacity', 'Native remap relationship capacity changed');
            FRow.A['remaps'].O[FIndex].S['outcome'] := 'applying';
            xeAutomationApplyFormIdRemap(remap, summary.A['dirtyFiles']);
            Inc(FApplied); summary.I['applied'] := summary.I['applied'] + 1;
            FRow.A['remaps'].O[FIndex].S['outcome'] := 'applied';
          end;
          // A finding admission failure after a write keeps the applied row/counter/audit.
          xeAutomationAddRemapFinding(findings, FKind, FFile, remap, not FDry);
          Inc(FIndex);
        end else FPhase := cspHeader;
        cspHeader: begin
          if not FDry and (Length(FRemaps) > 0) then begin
            if FMaxAfter < xeAutomationLightObjectIdLimit then FFile.NextObjectID := FMaxAfter + 1
            else FFile.NextObjectID := xeAutomationLightObjectIdLimit;
          end;
          FRow.B['complete'] := True; FPhase := cspComplete;
        end;
      end;
      // Visible phase boundaries, one loaded-file build or one whole remap per poll.
      if (FPhase <> oldPhase) or (oldPhase in [cspReferences, cspApply, cspHeader]) then Break;
    end;
  finally
    summary.I['findings'] := findings.Count;
    if Assigned(FRow) then begin
      FRow.I['newRecordCount'] := FCount; FRow.I['remapCount'] := Length(FRemaps);
      FRow.I['appliedRemaps'] := FApplied; FRow.I['nonEditableReferrers'] := FBlockers;
      FRow.S['phase'] := 'in_progress';
      if FPhase = cspComplete then FRow.S['phase'] := 'complete';
      UpdateAudit(summary);
    end;
  end;
  Result := FPhase = cspComplete;
end;

procedure TCompactStepper.WriteProgress(const progress: TJsonObject);
const phases: array[TCompactPhase] of string = ('file-tree', 'record-index', 'sort', 'reserve-ids',
  'plan', 'build-references', 'preflight', 'apply-remaps', 'next-object-id', 'complete');
begin
  progress.S['fileName'] := FName; progress.S['phase'] := phases[FPhase];
  if Assigned(FRow) then FRow.S['phase'] := phases[FPhase];
  progress.I['steps'] := FSteps; progress.I['lastWorkUnits'] := FLastWork;
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  progress.I['totalWorkUnits'] := FWork; progress.I['totalWorkLimit'] := xeAutomationEslScanWorkLimit;
  progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.I['retainedDepth'] := FStack.Count; progress.I['depthLimit'] := xeAutomationJobStepDepthLimit;
  progress.I['newRecordCount'] := FCount; progress.I['recordCapacity'] := Length(FRecords);
  progress.I['remapCount'] := Length(FRemaps); progress.I['appliedRemaps'] := FApplied;
  progress.I['loadedFilesProcessed'] := FModuleIndex; progress.I['loadedFilesTotal'] := Length(FModules);
  progress.I['referrersChecked'] := FReferrerIndex; progress.I['overridesChecked'] := FOverrideIndex;
  progress.I['relationshipsPerRemapLimit'] := xeAutomationCompactEdgeLimit;
  progress.I['mutationLimit'] := 1;
  progress.B['nativeCallsPreemptible'] := False;
  progress.S['nativeAtoms'] := 'container initialization/access; RecordCount sorting; one loaded-file reference build; one complete record/override/referrer remap; header setters and audit';
end;

function NewCompactStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin Result := TCompactStepper.Create(target.A['files'].S[0], kind, dry, True); end;

type
  TEslApplyPhase = (eapAnalyze, eapEligibility, eapCompact, eapFlag, eapComplete);
  TEslApplyStepper = class(TxeAutomationJobStepper)
  private
    FName: string;
    FDry, FAllowCompact, FRequiresCompact: Boolean;
    FFile: IwbFile;
    FRow: TJsonObject;
    FSnapshot: TxeAutomationMutationSnapshot;
    FAnalysis: TEslAnalysisStepper;
    FCompact: TCompactStepper;
    FChildSummary, FChildData, FLastChildProgress: TJsonObject;
    FPhase: TEslApplyPhase;
    FSteps, FReportedRemaps, FReportedPlans: Integer;
    procedure UpdateAudit(const summary: TJsonObject);
  public
    constructor Create(const name: string; const dry, allowCompact: Boolean);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TEslApplyStepper.Create(const name: string; const dry, allowCompact: Boolean);
begin
  inherited Create; FName := name; FDry := dry; FAllowCompact := allowCompact;
  FChildSummary := TJsonObject.Create; FChildData := TJsonObject.Create;
  FLastChildProgress := TJsonObject.Create;
  FAnalysis := TEslAnalysisStepper.Create(name);
end;

destructor TEslApplyStepper.Destroy;
begin
  FAnalysis.Free; FCompact.Free;
  FChildSummary.Free; FChildData.Free; FLastChildProgress.Free;
  FSnapshot.Files := nil; FFile := nil;
  inherited;
end;

procedure TEslApplyStepper.UpdateAudit(const summary: TJsonObject);
var i: Integer; fileRef: IwbFile; needsSave: Boolean;
begin
  xeAutomationWriteMutationAudit(FRow.O['mutationState'], FSnapshot);
  // Legacy apply dry rows project a changed flag, while summary.changed means
  // actual observed mutation. Keep both meanings distinct.
  FRow.B['changed'] := FRow.O['mutationState'].B['mutationsObserved'] or
    (FDry and FRow.B['eslFlagChanged']);
  summary.B['changed'] := summary.B['changed'] or FRow.O['mutationState'].B['mutationsObserved'];
  needsSave := False;
  for i := 0 to Length(FSnapshot.Files) - 1 do begin
    fileRef := FSnapshot.Files[i].FileRef;
    if fileRef.Modified and ((fileRef = FFile) or
       (fileRef.ElementGeneration <> FSnapshot.Files[i].Generation)) then begin
      xeAutomationAddDirtyFile(summary.A['dirtyFiles'], fileRef); needsSave := True;
    end;
  end;
  FRow.B['requiresSave'] := needsSave;
  summary.B['requiresSave'] := summary.B['requiresSave'] or needsSave;
end;

function TEslApplyStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var done, flagChanged: Boolean; analysisRow, oldFlags, newFlags: TJsonObject;
begin
  Inc(FSteps);
  try
    if not Assigned(FFile) then begin
      FFile := xeAutomationRequirePluginFile(FName);
      if not FDry then xeAutomationRequireWritableEslMutationTarget(FFile);
      FSnapshot := xeAutomationCaptureMutationSnapshot;
      FRow := resultData.A['files'].AddObject;
      FRow.S['fileName'] := FFile.FileName; FRow.B['complete'] := False;
      FRow.B['analysisComplete'] := False; FRow.B['compacted'] := False;
      FRow.I['remapCount'] := 0; FRow.I['appliedRemaps'] := 0;
      FRow.S['flagOutcome'] := 'not_started';
      summary.I['targets'] := summary.I['targets'] + 1;
      if not summary.Contains('planned') then summary.I['planned'] := 0;
      if not summary.Contains('applied') then summary.I['applied'] := 0;
      summary.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush';
    end;
    case FPhase of
      eapAnalyze: begin
        try done := FAnalysis.Advance(findings, FChildSummary, FChildData, failure);
        finally
          FAnalysis.WriteProgress(FLastChildProgress);
          if FChildData.A['files'].Count > 0 then FRow.O['analysis'].Assign(FChildData.A['files'].O[0]);
        end;
        if done then begin
          FRow.B['analysisComplete'] := True;
          FreeAndNil(FAnalysis); FPhase := eapEligibility;
        end;
      end;
      eapEligibility: begin
        analysisRow := FRow.O['analysis'];
        if analysisRow.B['eligible'] then FRequiresCompact := False
        else if FAllowCompact and (analysisRow.A['blockers'].Count = 0) and analysisRow.B['requiresCompact'] then
          FRequiresCompact := True
        else raise xeAutomationNewError(xeAutomationErrorEligibilityFailed,
          Format('%s is not currently eligible for ESL flag application', [FFile.FileName]));
        FRow.B['requiresCompact'] := FRequiresCompact;
        FChildSummary.Clear; FLastChildProgress.Clear;
        if FRequiresCompact then begin
          // Borrow the durable parent row; only the job result owns it. Preserve
          // this route's original policy: no per-remap reference refresh.
          FCompact := TCompactStepper.Create(FName, xeAutomationEslApplyKind, FDry, False, FRow);
          FPhase := eapCompact;
        end else FPhase := eapFlag;
      end;
      eapCompact: begin
        try done := FCompact.Advance(findings, FChildSummary, FChildData, failure);
        finally FCompact.WriteProgress(FLastChildProgress); end;
        if done then begin
          FRow.B['compacted'] := not FDry;
          FreeAndNil(FCompact); FPhase := eapFlag;
        end;
      end;
      eapFlag: begin
        // Separate poll after eligibility or ALL compact remaps/header updates.
        // Capture old flags at the same point as the legacy ESL apply handler.
        oldFlags := xeAutomationNewHeaderFlags(FFile);
        try
          FRow.O['oldFlags'].Assign(oldFlags);
          if not FDry then begin
            xeAutomationRequireWritableEslMutationTarget(FFile);
            FRow.S['flagOutcome'] := 'applying';
            if not FFile.IsLight then FFile.IsLight := True;
          end;
          newFlags := xeAutomationNewHeaderFlags(FFile);
          try
            if FDry then newFlags.B['esl'] := True;
            FRow.O['newFlags'].Assign(newFlags);
            flagChanged := oldFlags.B['esl'] <> newFlags.B['esl'];
            FRow.B['eslFlagChanged'] := flagChanged;
            FRow.B['isLight'] := FFile.IsLight;
            if FDry then begin
              FRow.S['flagOutcome'] := 'planned'; summary.I['planned'] := summary.I['planned'] + 1;
            end else begin
              FRow.S['flagOutcome'] := 'applied';
              if flagChanged then summary.I['applied'] := summary.I['applied'] + 1;
            end;
            // Applied flag state/counters remain visible if finding admission fails.
            xeAutomationAddEslApplyFinding(findings, FFile, oldFlags.B['esl'], newFlags.B['esl'], not FDry);
          finally newFlags.Free; end;
        finally oldFlags.Free; end;
        FPhase := eapComplete;
      end;
    end;
  finally
    if Assigned(FRow) then begin
      // Compaction completion alone must never complete the containing apply job.
      FRow.B['complete'] := FPhase = eapComplete;
      summary.I['remapsApplied'] := summary.I['remapsApplied'] + FRow.I['appliedRemaps'] - FReportedRemaps;
      FReportedRemaps := FRow.I['appliedRemaps'];
      FRow.I['plannedRemaps'] := FChildSummary.I['planned'];
      summary.I['remapsPlanned'] := summary.I['remapsPlanned'] + FRow.I['plannedRemaps'] - FReportedPlans;
      FReportedPlans := FRow.I['plannedRemaps'];
      UpdateAudit(summary);
    end;
    summary.I['findings'] := findings.Count;
  end;
  Result := FPhase = eapComplete;
end;

procedure TEslApplyStepper.WriteProgress(const progress: TJsonObject);
const phases: array[TEslApplyPhase] of string = ('analyze', 'eligibility', 'compact', 'esl-flag', 'complete');
begin
  progress.S['fileName'] := FName; progress.S['phase'] := phases[FPhase]; progress.I['steps'] := FSteps;
  progress.O['cursor'].Assign(FLastChildProgress);
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit; progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.I['mutationLimit'] := 1; progress.B['nativeCallsPreemptible'] := False;
  if Assigned(FRow) then begin
    FRow.S['phase'] := phases[FPhase];
    progress.I['appliedRemaps'] := FRow.I['appliedRemaps'];
    progress.S['flagOutcome'] := FRow.S['flagOutcome'];
  end;
  progress.S['nativeAtoms'] := 'analysis native getters/access; compaction file reference builds and whole remaps; ESL flag setter; audit';
end;

function NewEslApplyStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin
  Result := TEslApplyStepper.Create(target.A['files'].S[0], dry,
    xeAutomationReadBooleanOption(options, 'allowAfterCompact', False));
end;

procedure xeAutomationRegisterPluginAnalysisCommands;
begin
  // Capability advertising is registry-derived; registering these kinds here is
  // the single point that makes Task 3 compact/apply visible to clients.
  xeAutomationRegisterJobKindWithValidator(xeAutomationEslAnalyzeKind, xeAutomationPluginEslAnalyzeJob,
    xeAutomationValidateEslAnalyzeStart);
  xeAutomationRegisterJobStepper(xeAutomationEslAnalyzeKind, NewEslAnalysisStepper);
  xeAutomationRegisterJobKindWithValidator(xeAutomationFormIdsCompactForEslKind, xeAutomationPluginFormIdsCompactForEslJob,
    xeAutomationValidateCompactForEslStart);
  xeAutomationRegisterJobStepper(xeAutomationFormIdsCompactForEslKind, NewCompactStepper);
  xeAutomationRegisterJobKindWithValidator(xeAutomationEslApplyKind, xeAutomationPluginEslApplyJob,
    xeAutomationValidateEslApplyStart);
  xeAutomationRegisterJobStepper(xeAutomationEslApplyKind, NewEslApplyStepper);
end;

end.
