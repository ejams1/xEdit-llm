{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsFormIds;

interface

procedure xeAutomationRegisterFormIdCommands;

implementation

uses
  SysUtils,
  JsonDataObjects,
  wbInterface,
  wbLoadOrder,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationMutationAudit,
  xeAutomationMutationPolicy,
  xeAutomationObjectModel,
  xeAutomationRecordQueries,
  xeAutomationRegistry;

const
  MaxMappings = 32;
  MaxReferrers = 1024;

type
  TxeFormIdMapping = record
    RecordRef: IwbMainRecord;
    OldId, NewId: TwbFormID;
    NewMaster: IwbFile;
    Overrides: TArray<IwbMainRecord>;
    Referrers: TArray<IwbMainRecord>;
  end;

  TxeReferenceMapping = record
    OldId, NewId: TwbFormID;
    NewOwner: IwbFile;
    Referrers: TArray<IwbMainRecord>;
    ExcludedCount: Integer;
  end;

function xeFormIdsReadBoolean(const AArgs: TJsonObject; const AName: string;
  const ADefault: Boolean): Boolean;
begin
  Result := ADefault;
  if not AArgs.Contains(AName) then
    Exit;
  if AArgs.Types[AName] <> jdtBool then
    raise xeAutomationInvalidRequest(Format('Automation arg "%s" must be boolean', [AName]));
  Result := AArgs.B[AName];
end;

procedure xeFormIdsAddUniqueFile(const ATarget: TJsonArray; const AFile: IwbFile);
var
  i: Integer;
begin
  if not Assigned(AFile) then
    Exit;
  for i := 0 to ATarget.Count - 1 do
    if SameText(ATarget.S[i], AFile.FileName) then
      Exit;
  ATarget.Add(AFile.FileName);
end;

function xeFormIdsFileForId(const AId: TwbFormID): IwbFile;
var
  lModules: TwbModuleInfos;
  lFile: IwbFile;
  i: Integer;
begin
  Result := nil;
  lModules := wbModulesByLoadOrder;
  for i := Low(lModules) to High(lModules) do begin
    lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
    if Assigned(lFile) and (lFile.LoadOrderFileID = AId.FileID) then
      Exit(lFile);
  end;
end;

procedure xeFormIdsBuildRefIndex;
var
  lModules: TwbModuleInfos;
  lFile: IwbFile;
  i: Integer;
begin
  lModules := wbModulesByLoadOrder;
  for i := Low(lModules) to High(lModules) do begin
    lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
    if Assigned(lFile) then
      lFile.BuildOrLoadRef(False);
  end;
end;

procedure xeFormIdsRequireSupportedMode;
begin
  if wbGameMode = gmTES3 then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
      'FormID workflows require a game with numeric FormIDs');
  if wbTranslationMode then
    raise xeAutomationMutationNotAllowed('FormID workflows are unavailable in translation mode');
end;

procedure xeFormIdsPreflightDependency(const AFile, AOwner: IwbFile;
  const AAddMasters: Boolean);
begin
  if AFile.Equals(AOwner) then
    Exit;
  if AOwner.LoadOrder >= AFile.LoadOrder then
    raise xeAutomationInvalidTarget('New FormID owner must load before every affected plugin');
  if AFile.HasMaster(AOwner.FileName) then
    Exit;
  if not AAddMasters then
    raise xeAutomationMutationNotAllowed('Affected plugin requires a missing master; set addRequiredMasters:true');
  // Match the native Starfield AddMaster gate before any dependency writes.
  if wbStarfieldReverseEngineeringIncomplete and wbComplexFileFileID and
     ((AFile.ModuleType <> mtFull) or (AOwner.ModuleType <> mtFull)) then
    raise xeAutomationMutationNotAllowed('Native Starfield master additions require full modules');
end;

procedure xeFormIdsAddDependency(const AFile, AOwner: IwbFile;
  const ADirtyFiles: TJsonArray);
begin
  if not AFile.Equals(AOwner) and not AFile.HasMaster(AOwner.FileName) then begin
    AFile.AddMasterIfMissing(AOwner.FileName, True, True);
    xeFormIdsAddUniqueFile(ADirtyFiles, AFile);
  end;
end;

function xeFormIdsRequireMappings(const AArgs: TJsonObject): TJsonArray;
begin
  if not AArgs.Contains('mappings') or (AArgs.Types['mappings'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Automation formids.remap requires mappings array');
  Result := AArgs.A['mappings'];
  if (Result.Count < 1) or (Result.Count > MaxMappings) then
    raise xeAutomationInvalidRequest('Automation formids.remap requires 1..32 mappings');
end;

procedure xeFormIdsPreflightMapping(const AEntry: TJsonObject;
  const AUpdateRefs, AAddRequiredMasters, ADryRun: Boolean;
  out AMapping: TxeFormIdMapping);
var
  lLocator: TxeAutomationLocator;
  lFile: IwbFile;
  lCollision: TxeAutomationMainRecordSearch;
  lMaster: IwbMainRecord;
  i: Integer;
begin
  lLocator.FileName := xeAutomationRequireStringArg(AEntry, 'file');
  lLocator.FormID := xeAutomationRequireStringArg(AEntry, 'oldFormId');
  lLocator.Path := '';
  AMapping.RecordRef := xeAutomationRequireOwnedMainRecord(lLocator);
  AMapping.OldId := AMapping.RecordRef.LoadOrderFormID;
  AMapping.NewId := xeAutomationRequireFormID(xeAutomationRequireStringArg(AEntry, 'newFormId'));
  if AMapping.NewId.IsNull or AMapping.NewId.IsPlayer or (AMapping.NewId = AMapping.OldId) then
    raise xeAutomationInvalidRequest('New FormID must differ from old and cannot be null/player');
  if AMapping.RecordRef.Signature = 'TES4' then
    raise xeAutomationMutationNotAllowed('Plugin headers cannot be remapped');
  if not AMapping.RecordRef.MasterOrSelf.Equals(AMapping.RecordRef) then
    raise xeAutomationMutationNotAllowed('Remap the base record, not a later override');

  lFile := AMapping.RecordRef._File;
  if not ADryRun then
    xeAutomationRequireWritableRootRecordTarget(AMapping.RecordRef);
  lCollision := xeAutomationFindMainRecordsByLoadOrderFormID(AMapping.NewId.ToString(False));
  if Length(lCollision.Hits) > 0 then
    raise xeAutomationNewError('formid_collision',
      Format('Target FormID %s already belongs to a loaded record', [AMapping.NewId.ToString(True)]));

  AMapping.NewMaster := xeFormIdsFileForId(AMapping.NewId);
  if not Assigned(AMapping.NewMaster) then
    raise xeAutomationInvalidTarget('New FormID file slot does not belong to a loaded plugin');
  if (AMapping.NewId.ObjectID = 0) or
     ((AMapping.NewId.ObjectID < $800) and not AMapping.NewMaster.AllowHardcodedRangeUse) then
    raise xeAutomationInvalidTarget('New FormID object index is outside the target file allowed range');
  if AMapping.NewMaster.IsLight and (AMapping.NewId.ObjectID > $FFF) then
    raise xeAutomationInvalidTarget('New FormID exceeds the light-plugin object index range');
  if AMapping.NewMaster.IsMedium and (AMapping.NewId.ObjectID > $FFFF) then
    raise xeAutomationInvalidTarget('New FormID exceeds the medium-plugin object index range');
  xeFormIdsPreflightDependency(lFile, AMapping.NewMaster, AAddRequiredMasters);

  if AMapping.RecordRef.OverrideCount > MaxReferrers then
    raise xeAutomationNewError('reference_capacity', 'Remap exceeds 1024 overrides');
  SetLength(AMapping.Overrides, AMapping.RecordRef.OverrideCount);
  for i := 0 to Pred(AMapping.RecordRef.OverrideCount) do begin
    AMapping.Overrides[i] := AMapping.RecordRef.Overrides[i];
    xeFormIdsPreflightDependency(AMapping.Overrides[i]._File, AMapping.NewMaster, AAddRequiredMasters);
    if not ADryRun then
      xeAutomationRequireWritableRootRecordTarget(AMapping.Overrides[i]);
  end;
  if not AUpdateRefs then
    Exit;
  lMaster := AMapping.RecordRef.MasterOrSelf;
  if lMaster.ReferencedByCount > MaxReferrers then
    raise xeAutomationNewError('reference_capacity', 'Remap has more than 1024 referrers; narrow the workflow');
  SetLength(AMapping.Referrers, lMaster.ReferencedByCount);
  for i := 0 to Pred(lMaster.ReferencedByCount) do begin
    AMapping.Referrers[i] := lMaster.ReferencedBy[i];
    if Assigned(AMapping.Referrers[i]) then
      xeFormIdsPreflightDependency(AMapping.Referrers[i]._File, AMapping.NewMaster, AAddRequiredMasters);
    if not ADryRun and Assigned(AMapping.Referrers[i]) then
      xeAutomationRequireWritableRootRecordTarget(AMapping.Referrers[i]);
  end;
end;

function xeAutomationFormIdsRemap(const AArgs: TJsonObject): TJsonObject;
var
  lEntries: TJsonArray;
  lMappings: TArray<TxeFormIdMapping>;
  lSnapshot: TxeAutomationMutationSnapshot;
  lEntry, lOutput, lChanged: TJsonObject;
  lDryRun, lUpdateRefs, lAddMasters: Boolean;
  lDeniedReason: string;
  i, j, lTotalReferrers, lTotalOverrides: Integer;
begin
  xeFormIdsRequireSupportedMode;
  lEntries := xeFormIdsRequireMappings(AArgs);
  lDryRun := xeFormIdsReadBoolean(AArgs, 'dryRun', True);
  lUpdateRefs := xeFormIdsReadBoolean(AArgs, 'updateRefs', True);
  lAddMasters := xeFormIdsReadBoolean(AArgs, 'addRequiredMasters', False);
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then
    Exit(xeAutomationErrorsBuildConsentRequired('formids.remap', 'records-mutation', lDeniedReason));
  xeFormIdsBuildRefIndex;
  SetLength(lMappings, lEntries.Count);
  lTotalReferrers := 0;
  lTotalOverrides := 0;
  for i := 0 to lEntries.Count - 1 do begin
    if lEntries.Types[i] <> jdtObject then
      raise xeAutomationInvalidRequest('Each FormID mapping must be an object');
    xeFormIdsPreflightMapping(lEntries.O[i], lUpdateRefs, lAddMasters, lDryRun, lMappings[i]);
    Inc(lTotalReferrers, Length(lMappings[i].Referrers));
    Inc(lTotalOverrides, Length(lMappings[i].Overrides));
    if lTotalOverrides > MaxReferrers then
      raise xeAutomationNewError('reference_capacity', 'Remap batch exceeds 1024 total overrides');
    if lTotalReferrers > MaxReferrers then
      raise xeAutomationNewError('reference_capacity', 'Remap batch exceeds 1024 total referrers');
    for j := 0 to i - 1 do
      if (lMappings[j].OldId = lMappings[i].OldId) or
         (lMappings[j].NewId = lMappings[i].NewId) then
        raise xeAutomationInvalidRequest('Mappings must have unique old and new FormIDs');
  end;

  lSnapshot := xeAutomationCaptureMutationSnapshot;
  Result := TJsonObject.Create;
  try
    Result.B['dryRun'] := lDryRun;
    Result.B['complete'] := False;
    Result.S['persistence'] := 'in-memory-until-session.save';
    Result.I['planned'] := lEntries.Count;
    Result.I['completed'] := 0;
    Result.A['mappings'].Clear;
    Result.A['dirtyFiles'].Clear;
    for i := 0 to lEntries.Count - 1 do begin
      lOutput := Result.A['mappings'].AddObject;
      lOutput.I['index'] := i;
      lOutput.S['file'] := lMappings[i].RecordRef._File.FileName;
      lOutput.S['signature'] := lMappings[i].RecordRef.Signature;
      lOutput.S['oldFormId'] := lMappings[i].OldId.ToString(False);
      lOutput.S['newFormId'] := lMappings[i].NewId.ToString(False);
      lOutput.I['overrideCount'] := Length(lMappings[i].Overrides);
      lOutput.I['referrerCount'] := Length(lMappings[i].Referrers);
      lOutput.B['applied'] := False;
      lOutput.A['records'].Clear;
    end;
    if not lDryRun then begin
      // Dependency writes precede ID assignments. Every target, override and
      // referrer was checked before this point; native failures remain partial.
      for i := 0 to lEntries.Count - 1 do begin
        try
          xeFormIdsAddDependency(lMappings[i].RecordRef._File, lMappings[i].NewMaster, Result.A['dirtyFiles']);
          for j := Low(lMappings[i].Overrides) to High(lMappings[i].Overrides) do
            xeFormIdsAddDependency(lMappings[i].Overrides[j]._File, lMappings[i].NewMaster, Result.A['dirtyFiles']);
          for j := Low(lMappings[i].Referrers) to High(lMappings[i].Referrers) do
            if Assigned(lMappings[i].Referrers[j]) then
              xeFormIdsAddDependency(lMappings[i].Referrers[j]._File, lMappings[i].NewMaster, Result.A['dirtyFiles']);
          lMappings[i].RecordRef.LoadOrderFormID := lMappings[i].NewId;
          // Keep subsequent record allocation beyond IDs consumed in this file.
          if lMappings[i].NewMaster.Equals(lMappings[i].RecordRef._File) and
             (lMappings[i].NewId.ObjectID >= lMappings[i].RecordRef._File.NextObjectID) then
            lMappings[i].RecordRef._File.NextObjectID := lMappings[i].NewId.ObjectID + 1;
          xeFormIdsAddUniqueFile(Result.A['dirtyFiles'], lMappings[i].RecordRef._File);
          lEntry := Result.A['mappings'].O[i];
          lChanged := lEntry.A['records'].AddObject;
          lChanged.S['role'] := 'record';
          lChanged.S['file'] := lMappings[i].RecordRef._File.FileName;
          lChanged.S['formId'] := lMappings[i].RecordRef.LoadOrderFormID.ToString(False);
          for j := Low(lMappings[i].Overrides) to High(lMappings[i].Overrides) do begin
            lMappings[i].Overrides[j].LoadOrderFormID := lMappings[i].NewId;
            xeFormIdsAddUniqueFile(Result.A['dirtyFiles'], lMappings[i].Overrides[j]._File);
            lChanged := lEntry.A['records'].AddObject;
            lChanged.S['role'] := 'override';
            lChanged.S['file'] := lMappings[i].Overrides[j]._File.FileName;
            lChanged.S['formId'] := lMappings[i].Overrides[j].LoadOrderFormID.ToString(False);
          end;
          for j := Low(lMappings[i].Referrers) to High(lMappings[i].Referrers) do
            if Assigned(lMappings[i].Referrers[j]) and
               lMappings[i].Referrers[j].CompareExchangeFormID(lMappings[i].OldId, lMappings[i].NewId) then begin
              xeFormIdsAddUniqueFile(Result.A['dirtyFiles'], lMappings[i].Referrers[j]._File);
              lChanged := Result.A['mappings'].O[i].A['changedReferrers'].AddObject;
              lChanged.S['file'] := lMappings[i].Referrers[j]._File.FileName;
              lChanged.S['formId'] := lMappings[i].Referrers[j].LoadOrderFormID.ToString(False);
              lChanged := lEntry.A['records'].AddObject;
              lChanged.S['role'] := 'referrer';
              lChanged.S['file'] := lMappings[i].Referrers[j]._File.FileName;
              lChanged.S['formId'] := lMappings[i].Referrers[j].LoadOrderFormID.ToString(False);
              lMappings[i].Referrers[j].UpdateRefs;
            end;
          lEntry := Result.A['mappings'].O[i];
          lEntry.B['applied'] := True;
          Result.I['completed'] := i + 1;
        except
          on E: ExeAutomationError do begin
            Result.O['failure'].S['code'] := E.Code;
            Result.O['failure'].S['message'] := E.Message;
            if Assigned(E.Details) then
              Result.O['failure'].O['details'].Assign(E.Details);
            Result.O['failure'].I['index'] := i;
            Break;
          end;
          on E: Exception do begin
            Result.O['failure'].S['code'] := xeAutomationErrorInternalError;
            Result.O['failure'].S['message'] := E.Message;
            Result.O['failure'].I['index'] := i;
            Break;
          end;
        end;
      end;
      xeAutomationInvalidateRecordQueries;
    end;
    Result.B['complete'] := lDryRun or not Result.Contains('failure');
    if not lDryRun then begin
      xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      if Result.Contains('failure') then begin
        Result.O['failure'].I['completedMappings'] := Result.I['completed'];
        Result.O['failure'].I['notAttempted'] := lEntries.Count - i - 1;
        if Result.B['changed'] then begin
          Result.O['failure'].B['partial'] := True;
          Result.O['failure'].B['partialKnown'] := True;
        end else begin
          Result.O['failure']['partial'] := nil;
          Result.O['failure'].B['partialKnown'] := False;
        end;
      end;
    end else
      Result.B['changed'] := False;
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationReferencesReplace(const AArgs: TJsonObject): TJsonObject;
var
  lEntries, lScopeNames: TJsonArray;
  lScope: TArray<IwbFile>;
  lMappings: TArray<TxeReferenceMapping>;
  lSearchOld, lSearchNew: TxeAutomationMainRecordSearch;
  lOldMaster, lReferrer: IwbMainRecord;
  lEntry, lChanged: TJsonObject;
  lSnapshot: TxeAutomationMutationSnapshot;
  lDryRun, lAddMasters, lSelected: Boolean;
  lDeniedReason: string;
  i, j, k, n, lTotalReferrers: Integer;
begin
  xeFormIdsRequireSupportedMode;
  if not AArgs.Contains('mappings') or (AArgs.Types['mappings'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Automation references.replace requires mappings array');
  lEntries := AArgs.A['mappings'];
  if (lEntries.Count < 1) or (lEntries.Count > MaxMappings) then
    raise xeAutomationInvalidRequest('Automation references.replace requires 1..32 mappings');
  if not AArgs.Contains('scopeFiles') or (AArgs.Types['scopeFiles'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Automation references.replace requires scopeFiles array');
  lScopeNames := AArgs.A['scopeFiles'];
  if (lScopeNames.Count < 1) or (lScopeNames.Count > 32) then
    raise xeAutomationInvalidRequest('Automation references.replace requires 1..32 scope files');
  lDryRun := xeFormIdsReadBoolean(AArgs, 'dryRun', True);
  lAddMasters := xeFormIdsReadBoolean(AArgs, 'addRequiredMasters', False);
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then
    Exit(xeAutomationErrorsBuildConsentRequired('references.replace', 'records-mutation', lDeniedReason));
  SetLength(lScope, lScopeNames.Count);
  for i := 0 to lScopeNames.Count - 1 do begin
    if lScopeNames.Types[i] <> jdtString then
      raise xeAutomationInvalidRequest('scopeFiles entries must be strings');
    lScope[i] := xeAutomationRequirePluginFile(Trim(lScopeNames.S[i]));
  end;
  xeFormIdsBuildRefIndex;
  SetLength(lMappings, lEntries.Count);
  lTotalReferrers := 0;
  for i := 0 to lEntries.Count - 1 do begin
    if lEntries.Types[i] <> jdtObject then
      raise xeAutomationInvalidRequest('Each reference mapping must be an object');
    lMappings[i].OldId := xeAutomationRequireFormID(
      xeAutomationRequireStringArg(lEntries.O[i], 'oldFormId'));
    lMappings[i].NewId := xeAutomationRequireFormID(
      xeAutomationRequireStringArg(lEntries.O[i], 'newFormId'));
    if lMappings[i].OldId = lMappings[i].NewId then
      raise xeAutomationInvalidRequest('Old and new FormIDs must differ');
    for j := 0 to i - 1 do begin
      if lMappings[j].OldId = lMappings[i].OldId then
        raise xeAutomationInvalidRequest('Reference mappings must have unique old FormIDs');
      // Snapshots describe original references. Reject chains/swaps rather than
      // silently cascading a previous replacement through another mapping.
      if (lMappings[j].NewId = lMappings[i].OldId) or
         (lMappings[j].OldId = lMappings[i].NewId) then
        raise xeAutomationInvalidRequest('Reference mapping chains and swaps require separate requests');
    end;
    lSearchOld := xeAutomationFindMainRecordsByLoadOrderFormID(lMappings[i].OldId.ToString(False));
    lSearchNew := xeAutomationFindMainRecordsByLoadOrderFormID(lMappings[i].NewId.ToString(False));
    if not Assigned(lSearchOld.MasterOrSelf) or not Assigned(lSearchNew.MasterOrSelf) then
      raise xeAutomationInvalidTarget('Both old and new reference targets must be loaded records');
    lOldMaster := lSearchOld.MasterOrSelf;
    lMappings[i].NewOwner := lSearchNew.MasterOrSelf._File;
    for j := 0 to Pred(lOldMaster.ReferencedByCount) do begin
      lReferrer := lOldMaster.ReferencedBy[j];
      if not Assigned(lReferrer) then
        Continue;
      lSelected := False;
      for k := Low(lScope) to High(lScope) do
        if SameText(lReferrer._File.FileName, lScope[k].FileName) then begin
          lSelected := True;
          Break;
        end;
      if not lSelected then begin
        Inc(lMappings[i].ExcludedCount);
        Continue;
      end;
      if Length(lMappings[i].Referrers) >= MaxReferrers then
        raise xeAutomationNewError('reference_capacity', 'Mapping exceeds 1024 in-scope referrers');
      xeFormIdsPreflightDependency(lReferrer._File, lMappings[i].NewOwner, lAddMasters);
      if not lDryRun then
        xeAutomationRequireWritableRootRecordTarget(lReferrer);
      n := Length(lMappings[i].Referrers);
      Inc(lTotalReferrers);
      if lTotalReferrers > MaxReferrers then
        raise xeAutomationNewError('reference_capacity', 'Replacement batch exceeds 1024 total referrers');
      SetLength(lMappings[i].Referrers, n + 1);
      lMappings[i].Referrers[n] := lReferrer;
    end;
  end;

  lSnapshot := xeAutomationCaptureMutationSnapshot;
  Result := TJsonObject.Create;
  try
    Result.B['dryRun'] := lDryRun;
    Result.B['complete'] := False;
    Result.S['persistence'] := 'in-memory-until-session.save';
    Result.I['planned'] := lEntries.Count;
    Result.I['completed'] := 0;
    Result.A['mappings'].Clear;
    Result.A['dirtyFiles'].Clear;
    for i := 0 to lEntries.Count - 1 do begin
      lEntry := Result.A['mappings'].AddObject;
      lEntry.I['index'] := i;
      lEntry.S['oldFormId'] := lMappings[i].OldId.ToString(False);
      lEntry.S['newFormId'] := lMappings[i].NewId.ToString(False);
      lEntry.I['inScopeReferrers'] := Length(lMappings[i].Referrers);
      lEntry.I['excludedReferrers'] := lMappings[i].ExcludedCount;
      lEntry.I['changedRecords'] := 0;
      lEntry.A['records'].Clear;
    end;
    if not lDryRun then begin
      for i := 0 to lEntries.Count - 1 do begin
        try
          for j := Low(lMappings[i].Referrers) to High(lMappings[i].Referrers) do begin
            lReferrer := lMappings[i].Referrers[j];
            xeFormIdsAddDependency(lReferrer._File, lMappings[i].NewOwner, Result.A['dirtyFiles']);
            if lReferrer.CompareExchangeFormID(lMappings[i].OldId, lMappings[i].NewId) then begin
              xeFormIdsAddUniqueFile(Result.A['dirtyFiles'], lReferrer._File);
              lEntry := Result.A['mappings'].O[i];
              lEntry.I['changedRecords'] := lEntry.I['changedRecords'] + 1;
              lChanged := lEntry.A['records'].AddObject;
              lChanged.S['file'] := lReferrer._File.FileName;
              lChanged.S['formId'] := lReferrer.LoadOrderFormID.ToString(False);
              lChanged.S['signature'] := lReferrer.Signature;
              lReferrer.UpdateRefs;
            end;
          end;
          Result.I['completed'] := i + 1;
        except
          on E: ExeAutomationError do begin
            Result.O['failure'].S['code'] := E.Code;
            Result.O['failure'].S['message'] := E.Message;
            if Assigned(E.Details) then
              Result.O['failure'].O['details'].Assign(E.Details);
            Result.O['failure'].I['index'] := i;
            Break;
          end;
          on E: Exception do begin
            Result.O['failure'].S['code'] := xeAutomationErrorInternalError;
            Result.O['failure'].S['message'] := E.Message;
            Result.O['failure'].I['index'] := i;
            Break;
          end;
        end;
      end;
      xeAutomationInvalidateRecordQueries;
    end;
    Result.B['complete'] := lDryRun or not Result.Contains('failure');
    if lDryRun then
      Result.B['changed'] := False
    else begin
      xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      if Result.Contains('failure') then begin
        Result.O['failure'].I['completedMappings'] := Result.I['completed'];
        Result.O['failure'].I['notAttempted'] := lEntries.Count - i - 1;
        if Result.B['changed'] then begin
          Result.O['failure'].B['partial'] := True;
          Result.O['failure'].B['partialKnown'] := True;
        end else begin
          Result.O['failure']['partial'] := nil;
          Result.O['failure'].B['partialKnown'] := False;
        end;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function xeFormIdsSelectedRecords(const AArgs: TJsonObject; const AFile: IwbFile): TxeAutomationMainRecords;
var
  lIds: TJsonArray;
  lRecord, lTemp: IwbMainRecord;
  i, j: Integer;
begin
  if not AArgs.Contains('formIds') then
    Result := xeAutomationCollectNewMainRecordsInFile(AFile)
  else begin
    if AArgs.Types['formIds'] <> jdtArray then
      raise xeAutomationInvalidRequest('formIds must be an array');
    lIds := AArgs.A['formIds'];
    SetLength(Result, lIds.Count);
    for i := 0 to lIds.Count - 1 do begin
      if lIds.Types[i] <> jdtString then
        raise xeAutomationInvalidRequest('formIds entries must be strings');
      lRecord := xeAutomationResolveOwnedMainRecordInFile(AFile, Trim(lIds.S[i]));
      if not Assigned(lRecord) then
        raise xeAutomationRecordNotFound(AFile.FileName, lIds.S[i]);
      if not lRecord.MasterOrSelf.Equals(lRecord) then
        raise xeAutomationMutationNotAllowed('Renumber/inject selection must contain base records');
      Result[i] := lRecord;
    end;
  end;
  if (Length(Result) < 1) or (Length(Result) > MaxMappings) then
    raise xeAutomationInvalidRequest('Renumber/inject selection must contain 1..32 records');
  for i := Low(Result) to High(Result) do
    for j := i + 1 to High(Result) do
      if Result[j].LoadOrderFormID.ObjectID < Result[i].LoadOrderFormID.ObjectID then begin
        lTemp := Result[i];
        Result[i] := Result[j];
        Result[j] := lTemp;
      end;
  for i := Low(Result) to High(Result) do
    for j := i + 1 to High(Result) do
      if Result[i].Equals(Result[j]) then
        raise xeAutomationInvalidRequest('formIds selection contains duplicate records');
end;

function xeAutomationFormIdsChange(const AArgs: TJsonObject): TJsonObject;
var
  lRequest, lEntry: TJsonObject;
begin
  lRequest := AArgs.Clone;
  try
    lRequest.A['mappings'].Clear;
    lEntry := lRequest.A['mappings'].AddObject;
    lEntry.S['file'] := xeAutomationRequireStringArg(AArgs, 'file');
    lEntry.S['oldFormId'] := xeAutomationRequireStringArg(AArgs, 'formId');
    lEntry.S['newFormId'] := xeAutomationRequireStringArg(AArgs, 'newFormId');
    Result := xeAutomationFormIdsRemap(lRequest);
    Result.S['workflow'] := 'single-change';
  finally
    lRequest.Free;
  end;
end;

function xeAutomationFormIdsRenumber(const AArgs: TJsonObject): TJsonObject;
var
  lFile: IwbFile;
  lRecords: TxeAutomationMainRecords;
  lStart, lEnd, lNewId: TwbFormID;
  lRequest, lEntry: TJsonObject;
  i: Integer;
begin
  lFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  lStart := xeAutomationRequireFormID(xeAutomationRequireStringArg(AArgs, 'startFormId'));
  if lStart.FileID <> lFile.LoadOrderFileID then
    raise xeAutomationInvalidRequest('Renumber startFormId must use the source file load-order slot');
  lRecords := xeFormIdsSelectedRecords(AArgs, lFile);
  lEnd := lStart + Pred(Length(lRecords));
  if lEnd.FileID <> lStart.FileID then
    raise xeAutomationInvalidRequest('Renumber range crosses the target file slot');
  if AArgs.Contains('endFormId') and
     (lEnd > xeAutomationRequireFormID(xeAutomationRequireStringArg(AArgs, 'endFormId'))) then
    raise xeAutomationInvalidRequest('Renumber selection exceeds endFormId');
  lRequest := AArgs.Clone;
  try
    lRequest.A['mappings'].Clear;
    for i := Low(lRecords) to High(lRecords) do begin
      lNewId := lStart + i;
      lEntry := lRequest.A['mappings'].AddObject;
      lEntry.S['file'] := lFile.FileName;
      lEntry.S['oldFormId'] := lRecords[i].LoadOrderFormID.ToString(False);
      lEntry.S['newFormId'] := lNewId.ToString(False);
    end;
    Result := xeAutomationFormIdsRemap(lRequest);
    Result.S['workflow'] := 'renumber';
    Result.S['startFormId'] := lStart.ToString(False);
    Result.S['endFormId'] := lEnd.ToString(False);
  finally
    lRequest.Free;
  end;
end;

function xeAutomationFormIdsInject(const AArgs: TJsonObject): TJsonObject;
var
  lSource, lMaster: IwbFile;
  lRecords: TxeAutomationMainRecords;
  lStart, lNewId: TwbFormID;
  lPreserve: Boolean;
  lRequest, lEntry: TJsonObject;
  i: Integer;
begin
  lSource := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  lMaster := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'masterFile'));
  if lMaster.Equals(lSource) or (lMaster.LoadOrder >= lSource.LoadOrder) then
    raise xeAutomationInvalidTarget('Injection master must load before the source plugin');
  lRecords := xeFormIdsSelectedRecords(AArgs, lSource);
  lPreserve := xeFormIdsReadBoolean(AArgs, 'preserveObjectIds', True);
  if not lPreserve then begin
    lStart := xeAutomationRequireFormID(xeAutomationRequireStringArg(AArgs, 'startFormId'));
    if lStart.FileID <> lMaster.LoadOrderFileID then
      raise xeAutomationInvalidRequest('Injection startFormId must use master load-order slot');
    lNewId := lStart + Pred(Length(lRecords));
    if lNewId.FileID <> lStart.FileID then
      raise xeAutomationInvalidRequest('Injection range crosses the master file slot');
  end;
  lRequest := AArgs.Clone;
  try
    lRequest.A['mappings'].Clear;
    for i := Low(lRecords) to High(lRecords) do begin
      if lPreserve then
        lNewId := lRecords[i].LoadOrderFormID.ChangeFileID(lMaster.LoadOrderFileID)
      else
        lNewId := lStart + i;
      lEntry := lRequest.A['mappings'].AddObject;
      lEntry.S['file'] := lSource.FileName;
      lEntry.S['oldFormId'] := lRecords[i].LoadOrderFormID.ToString(False);
      lEntry.S['newFormId'] := lNewId.ToString(False);
    end;
    Result := xeAutomationFormIdsRemap(lRequest);
    Result.S['workflow'] := 'inject';
    Result.S['masterFile'] := lMaster.FileName;
    Result.B['preserveObjectIds'] := lPreserve;
  finally
    lRequest.Free;
  end;
end;

procedure xeAutomationRegisterFormIdCommands;
begin
  xeAutomationRegisterCommand('formids.remap', xeAutomationFormIdsRemap);
  xeAutomationRegisterCommand('formids.change', xeAutomationFormIdsChange);
  xeAutomationRegisterCommand('formids.renumber', xeAutomationFormIdsRenumber);
  xeAutomationRegisterCommand('formids.inject', xeAutomationFormIdsInject);
  xeAutomationRegisterCommand('references.replace', xeAutomationReferencesReplace);
end;

end.
