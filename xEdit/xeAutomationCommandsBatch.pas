{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsBatch;

interface

procedure xeAutomationRegisterBatchCommands;

implementation

uses
  Classes,
  SysUtils,
  JsonDataObjects,
  wbImplementation,
  wbInterface,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationMutationAudit,
  xeAutomationMutationPolicy,
  xeAutomationObjectModel,
  xeAutomationProjection,
  xeAutomationRegistry;

const
  xeAutomationBatchReadLimit = 32;
  xeAutomationBatchEditLimit = 16;
  xeAutomationBatchResponseBytes = 1048576;

type
  TxeAutomationBatchEditTarget = record
    Args: TJsonObject;
    RecordRef: IwbMainRecord;
    ElementRef: IwbElement;
    BeforeValue: string;
  end;

  TxeAutomationRowTarget = record
    Mode: string;
    RecordRef, SourceRecord: IwbMainRecord;
    ElementRef, SourceRef: IwbElement;
    RequiredMasters: TwbFiles;
  end;

function xeAutomationRequireBatchItems(const AArgs: TJsonObject; const AMax: Integer): TJsonArray;
begin
  if not Assigned(AArgs) or not AArgs.Contains('items') or (AArgs.Types['items'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Automation batch items must be an array');
  Result := AArgs.A['items'];
  if (Result.Count < 1) or (Result.Count > AMax) then
    raise xeAutomationInvalidRequest(Format('Automation batch requires 1..%d items', [AMax]));
end;

function xeAutomationRequireBatchItemArgs(const AItem: TJsonObject): TJsonObject;
begin
  if not AItem.Contains('args') or (AItem.Types['args'] <> jdtObject) then
    raise xeAutomationInvalidRequest('Automation batch item.args must be an object');
  Result := AItem.O['args'];
end;

procedure xeAutomationRequireBatchResponseBudget(const AResult: TJsonObject);
begin
  if TEncoding.UTF8.GetByteCount(AResult.ToJSON(False)) > xeAutomationBatchResponseBytes then
    raise xeAutomationNewError('result_too_large', 'Automation batch result exceeds 1 MiB; use fewer or narrower items');
end;

function xeAutomationBatchRead(const AArgs: TJsonObject): TJsonObject;
var
  lItems: TJsonArray;
  lItem, lArgs, lEntry, lValue: TJsonObject;
  lCommand: string;
  i: Integer;
begin
  lItems := xeAutomationRequireBatchItems(AArgs, xeAutomationBatchReadLimit);
  Result := TJsonObject.Create;
  try
    Result.I['total'] := lItems.Count;
    Result.B['complete'] := True;
    Result.A['items'].Clear;
    for i := 0 to lItems.Count - 1 do begin
      if lItems.Types[i] <> jdtObject then
        raise xeAutomationInvalidRequest('Automation batch item must be an object');
      lItem := lItems.O[i];
      lCommand := xeAutomationRequireStringArg(lItem, 'command');
      if not (SameText(lCommand, 'records.get') or SameText(lCommand, 'elements.get') or
              SameText(lCommand, 'elements.get_value') or SameText(lCommand, 'elements.children') or
              SameText(lCommand, 'elements.subtree')) then
        raise xeAutomationInvalidRequest(Format('Automation batch read command is unsupported: %s', [lCommand]));
      lArgs := xeAutomationRequireBatchItemArgs(lItem);
      xeAutomationValidateProjection(lArgs);
      if SameText(lCommand, 'elements.children') then begin
        if not lArgs.Contains('limit') then
          raise xeAutomationInvalidRequest('Automation batch children requires an explicit limit of at most 50');
        // A caller may ask for a narrower page, but cannot expand the per-item
        // materialization bound through a nested command.
        if xeAutomationReadChildrenLimitArg(lArgs, 'limit', 50) > 50 then
          raise xeAutomationInvalidRequest('Automation batch children limit must be at most 50');
      end;
      if SameText(lCommand, 'elements.subtree') then begin
        if not lArgs.Contains('maxNodes') then
          raise xeAutomationInvalidRequest('Automation batch subtree requires explicit maxNodes of at most 50');
        if xeAutomationReadChildrenLimitArg(lArgs, 'maxNodes', 50) > 50 then
          raise xeAutomationInvalidRequest('Automation batch subtree maxNodes must be at most 50');
      end;
      lValue := xeAutomationExecuteCommand(lCommand, lArgs);
      try
        xeAutomationProjectResponse(lValue, lArgs);
        lEntry := Result.A['items'].AddObject;
        lEntry.I['index'] := i;
        lEntry.S['command'] := lCommand;
        lEntry.O['result'] := lValue;
        lValue := nil;
        if SameText(lCommand, 'elements.subtree') and not lEntry.O['result'].B['complete'] then
          Result.B['complete'] := False;
        xeAutomationRequireBatchResponseBudget(Result);
      finally
        lValue.Free;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationBatchEdit(const AArgs: TJsonObject): TJsonObject;
var
  lItems: TJsonArray;
  lTargets: TArray<TxeAutomationBatchEditTarget>;
  lItem, lArgs, lEntry, lValue: TJsonObject;
  lLocator: TxeAutomationLocator;
  lSnapshot: TxeAutomationMutationSnapshot;
  lExpectedRevision, lDeniedReason: string;
  i, j: Integer;
begin
  lItems := xeAutomationRequireBatchItems(AArgs, xeAutomationBatchEditLimit);
  if TEncoding.UTF8.GetByteCount(AArgs.ToJSON(False)) > 262144 then
    raise xeAutomationInvalidRequest('Automation batch edit request must be at most 256 KiB');
  lExpectedRevision := xeAutomationRequireStringArg(AArgs, 'expectedRevision');
  if lExpectedRevision <> UIntToStr(wbGlobalModifedGeneration) then
    raise xeAutomationNewError('stale_revision', 'Loaded plugin revision differs from batch expectedRevision');
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then
    Exit(xeAutomationErrorsBuildConsentRequired('batch.edit', 'elements-mutation', lDeniedReason));

  SetLength(lTargets, lItems.Count);
  // Resolve every target and expectation before the first write. One mutation
  // per record prevents a sorted container from moving a later path in-batch.
  for i := 0 to lItems.Count - 1 do begin
    if lItems.Types[i] <> jdtObject then
      raise xeAutomationInvalidRequest('Automation batch item must be an object');
    lItem := lItems.O[i];
    if not SameText(xeAutomationRequireStringArg(lItem, 'command'), 'elements.set_value') then
      raise xeAutomationInvalidRequest('Automation batch edit supports elements.set_value only');
    lArgs := xeAutomationRequireBatchItemArgs(lItem);
    lLocator := xeAutomationParseLocator(lArgs, True, True);
    lTargets[i].ElementRef := xeAutomationRequireOwnedElement(lLocator, lTargets[i].RecordRef);
    xeAutomationRequireWritableElementTarget(lTargets[i].ElementRef);
    lTargets[i].BeforeValue := xeAutomationRequireRawStringArg(lArgs, 'expectedValue');
    xeAutomationRequireRawStringArg(lArgs, 'value');
    if lTargets[i].ElementRef.EditValue <> lTargets[i].BeforeValue then
      raise xeAutomationNewError('stale_value', Format('Batch item %d no longer matches expectedValue', [i]));
    for j := 0 to i - 1 do
      if lTargets[j].RecordRef.Equals(lTargets[i].RecordRef) then
        raise xeAutomationInvalidRequest('Automation batch permits one edit per record; split dependent edits into separate batches');
    lTargets[i].Args := lArgs;
  end;

  if lExpectedRevision <> UIntToStr(wbGlobalModifedGeneration) then
    raise xeAutomationNewError('stale_revision', 'Loaded plugin revision changed during batch preflight');

  lSnapshot := xeAutomationCaptureMutationSnapshot;
  Result := TJsonObject.Create;
  try
    Result.S['persistence'] := 'in-memory-until-session.save';
    Result.I['total'] := lItems.Count;
    Result.I['completed'] := 0;
    Result.B['complete'] := False;
    Result.A['items'].Clear;
    for i := 0 to lItems.Count - 1 do begin
      try
        lValue := xeAutomationExecuteCommand('elements.set_value', lTargets[i].Args);
        try
          if TEncoding.UTF8.GetByteCount(Result.ToJSON(False)) +
             TEncoding.UTF8.GetByteCount(lValue.ToJSON(False)) + 512 > xeAutomationBatchResponseBytes then begin
            Result.I['completed'] := i + 1;
            raise xeAutomationNewError('result_too_large',
              'Batch item was applied but its result exceeds the retained response budget');
          end;
          lEntry := Result.A['items'].AddObject;
          lEntry.I['index'] := i;
          lEntry.S['command'] := 'elements.set_value';
          lEntry.S['beforeValue'] := lTargets[i].BeforeValue;
          lEntry.O['result'] := lValue;
          lValue := nil;
          Result.I['completed'] := i + 1;
        finally
          lValue.Free;
        end;
      except
        on E: ExeAutomationError do begin
          Result.O['failure'].S['code'] := E.Code;
          Result.O['failure'].S['message'] := E.Message;
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
    Result.B['complete'] := (not Result.Contains('failure')) and
      (Result.I['completed'] = lItems.Count);
    xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
    Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
    if Result.Contains('failure') then begin
      Result.O['failure'].I['completed'] := Result.I['completed'];
      Result.O['failure'].I['notAttempted'] := lItems.Count - i - 1;
      if Result.B['changed'] then begin
        Result.O['failure'].B['partial'] := True;
        Result.O['failure'].B['partialKnown'] := True;
      end else begin
        Result.O['failure']['partial'] := nil;
        Result.O['failure'].B['partialKnown'] := False;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationRowContains(const AParent, AChild: IwbElement): Boolean;
var
  lElement: IwbElement;
  i: Integer;
begin
  lElement := AChild;
  // Compare native identity, not locator spelling: array aliases and sorting
  // can give the same row different paths. Bound malformed ancestry as well.
  for i := 0 to 32 do begin
    if not Assigned(lElement) then
      Exit(False);
    if lElement.Equals(AParent) then
      Exit(True);
    lElement := lElement.Container;
  end;
  raise xeAutomationInvalidTarget('Row ancestry exceeds 32 levels');
end;

procedure xeAutomationRowBoundScope(const AElement: IwbElement;
  const ADepth: Integer; var AVisits: Integer);
var
  lContainer: IwbContainer;
  i: Integer;
begin
  Inc(AVisits);
  if (AVisits > 2048) or (ADepth > 16) then
    raise xeAutomationInvalidRequest('Row batch exceeds 2048 visited elements or depth 16');
  if Supports(AElement, IwbContainer, lContainer) then begin
    if lContainer.ElementCount > 2048 - AVisits then
      raise xeAutomationInvalidRequest('Row scope exceeds the remaining element budget');
    for i := 0 to lContainer.ElementCount - 1 do
      xeAutomationRowBoundScope(lContainer.Elements[i], ADepth + 1, AVisits);
  end;
end;

procedure xeAutomationRowRequirePayload(const AElement: IwbElement;
  const ARecord: IwbMainRecord);
var
  lHeader: IwbElement;
begin
  // Header and root assignment can change identity or replace the whole record.
  // Native indexed paths do not carry row names. Test the actual header ancestry
  // so aliases and indexed descendants cannot bypass this scope boundary.
  lHeader := ARecord.ElementByPath['Record Header'];
  if AElement.Equals(ARecord) or
     (Assigned(lHeader) and xeAutomationRowContains(lHeader, AElement)) or
     (ARecord.Signature = 'TES4') or ARecord.IsDeleted or ARecord.IsPartialForm then
    raise xeAutomationInvalidTarget('Row operations require non-header children of full nondeleted records');
end;

procedure xeAutomationRowWriteLocator(const AJson: TJsonObject;
  const ARecord: IwbMainRecord; const AElement: IwbElement);
begin
  AJson.S['file'] := ARecord._File.FileName;
  AJson.S['formId'] := ARecord.LoadOrderFormID.ToString(False);
  AJson.S['path'] := xeAutomationElementLocatorPath(AElement);
end;

function xeAutomationRowIsArray(const AElement: IwbElement): Boolean;
begin
  // Packed KWDA-style arrays are subrecords themselves, not etArray children.
  Result := (AElement.ElementType in [etArray, etSubRecordArray]) or
    ((AElement.ElementType = etSubRecord) and Assigned(AElement.ValueDef) and
     (AElement.ValueDef.DefType = dtArray));
end;

function xeAutomationBatchRows(const AArgs: TJsonObject): TJsonObject;
var
  lItems: TJsonArray;
  lTargets: TArray<TxeAutomationRowTarget>;
  lItem, lEntry: TJsonObject;
  lLocator: TxeAutomationLocator;
  lMasters: TwbFilesSet;
  lMaster: IwbFile;
  lNewElement: IwbElement;
  lContainer: IwbContainer;
  lSnapshot: TxeAutomationMutationSnapshot;
  lFailure: ExeAutomationError;
  lRevision, lDeniedReason: string;
  lDryRun, lAddMasters, lPresent: Boolean;
  i, j, k, lVisits, lCount: Integer;
begin
  lItems := xeAutomationRequireBatchItems(AArgs, xeAutomationBatchEditLimit);
  if TEncoding.UTF8.GetByteCount(AArgs.ToJSON(False)) > 262144 then
    raise xeAutomationInvalidRequest('Row batch request must be at most 256 KiB');
  if (wbGameMode = gmTES3) or wbTranslationMode then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
      'Row batches require non-TES3 mode with translation mode off');
  lRevision := xeAutomationRequireStringArg(AArgs, 'expectedRevision');
  if lRevision <> UIntToStr(wbGlobalModifedGeneration) then
    raise xeAutomationNewError('stale_revision', 'Loaded plugin revision differs from row batch expectedRevision');
  lDryRun := xeAutomationReadBooleanArg(AArgs, 'dryRun', lPresent);
  if not lPresent then lDryRun := True;
  lAddMasters := xeAutomationReadBooleanArg(AArgs, 'addRequiredMasters', lPresent);
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then
    Exit(xeAutomationErrorsBuildConsentRequired('batch.rows', 'elements-mutation', lDeniedReason));

  lSnapshot := xeAutomationCaptureMutationSnapshot;
  SetLength(lTargets, lItems.Count);
  lVisits := 0;
  i := 0;
  try
    for i := 0 to lItems.Count - 1 do begin
      if lItems.Types[i] <> jdtObject then
        raise xeAutomationInvalidRequest('Row batch item must be an object');
      lItem := lItems.O[i];
      lTargets[i].Mode := LowerCase(xeAutomationRequireStringArg(lItem, 'mode'));
      if (lTargets[i].Mode <> 'replace') and (lTargets[i].Mode <> 'append') and
         (lTargets[i].Mode <> 'remove') then
        raise xeAutomationInvalidRequest('Row mode must be replace, append or remove');
      lLocator := xeAutomationParseNestedLocatorArg(lItem, 'target', True, True);
      lTargets[i].ElementRef := xeAutomationRequireOwnedElement(lLocator, lTargets[i].RecordRef);
      xeAutomationRowRequirePayload(lTargets[i].ElementRef, lTargets[i].RecordRef);
      xeAutomationRequireWritableTargetFile(lTargets[i].RecordRef._File);
      xeAutomationRowBoundScope(lTargets[i].ElementRef, 0, lVisits);
      if lTargets[i].Mode = 'remove' then begin
        if lItem.Contains('source') then
          raise xeAutomationInvalidRequest('Remove rows must omit source');
        xeAutomationRequireRemovableElementTarget(lTargets[i].ElementRef);
      end else begin
        lLocator := xeAutomationParseNestedLocatorArg(lItem, 'source', True, True);
        lTargets[i].SourceRef := xeAutomationRequireOwnedElement(lLocator, lTargets[i].SourceRecord);
        xeAutomationRowRequirePayload(lTargets[i].SourceRef, lTargets[i].SourceRecord);
        xeAutomationRowBoundScope(lTargets[i].SourceRef, 0, lVisits);
        if lTargets[i].Mode = 'append' then begin
          // Some native non-array Assign implementations replace even for an
          // add index. Restrict append to actual array containers, never infer it.
          if not xeAutomationRowIsArray(lTargets[i].ElementRef) then
            raise xeAutomationInvalidTarget('Append target must be an array container');
          xeAutomationRequireCopyTargetAt(lTargets[i].ElementRef, lTargets[i].SourceRef, wbAssignAdd);
        end else begin
          // Arrays can append at wbAssignThis, and union replacement can remove
          // Self while returning nil. Same native definitions/types keep this
          // route an existing-row payload replacement with stable row identity.
          if (lTargets[i].SourceRef.ElementType <> lTargets[i].ElementRef.ElementType) or
             not Assigned(lTargets[i].ElementRef.Def) or not Assigned(lTargets[i].SourceRef.Def) or
             not lTargets[i].ElementRef.Def.Equals(lTargets[i].SourceRef.Def) then
            raise xeAutomationInvalidTarget('Replace requires matching native row definitions and element types');
          xeAutomationRequireCopyTargetAt(lTargets[i].ElementRef, lTargets[i].SourceRef, wbAssignThis);
        end;
        lMasters := TwbFilesSet.Create;
        try
          lTargets[i].SourceRef.ReportRequiredMasters(lMasters, False, True, True);
          for lMaster in lMasters do begin
            if lMaster.Equals(lTargets[i].RecordRef._File) or
               lTargets[i].RecordRef._File.HasMaster(lMaster.FileName) then Continue;
            if not lAddMasters then
              raise xeAutomationMutationNotAllowed('Row copy needs missing masters; pass addRequiredMasters:true');
            if lMaster.LoadOrder >= lTargets[i].RecordRef._File.LoadOrder then
              raise xeAutomationInvalidTarget('Required row masters must load before the target');
            if wbStarfieldReverseEngineeringIncomplete and wbComplexFileFileID and
               ((lTargets[i].RecordRef._File.ModuleType <> mtFull) or (lMaster.ModuleType <> mtFull)) then
              raise xeAutomationMutationNotAllowed('Native Starfield master additions require full modules');
            k := Length(lTargets[i].RequiredMasters);
            SetLength(lTargets[i].RequiredMasters, k + 1);
            lTargets[i].RequiredMasters[k] := lMaster;
          end;
        finally
          lMasters.Free;
        end;
        // Master-set iteration is not a load-order contract. Add earlier masters
        // first, as the native GUI master helper does.
        for j := 0 to High(lTargets[i].RequiredMasters) do
          for k := j + 1 to High(lTargets[i].RequiredMasters) do
            if lTargets[i].RequiredMasters[k].LoadOrder < lTargets[i].RequiredMasters[j].LoadOrder then begin
              lMaster := lTargets[i].RequiredMasters[j];
              lTargets[i].RequiredMasters[j] := lTargets[i].RequiredMasters[k];
              lTargets[i].RequiredMasters[k] := lMaster;
            end;
      end;
    end;
    for i := 0 to High(lTargets) do begin
      for j := 0 to i - 1 do
        if xeAutomationRowContains(lTargets[i].ElementRef, lTargets[j].ElementRef) or
           xeAutomationRowContains(lTargets[j].ElementRef, lTargets[i].ElementRef) then
          raise xeAutomationInvalidRequest('Row batch targets must be distinct and must not overlap');
      for j := 0 to High(lTargets) do
        if Assigned(lTargets[i].SourceRecord) and
           lTargets[i].SourceRecord.Equals(lTargets[j].RecordRef) then
          raise xeAutomationInvalidRequest('Row source records must not also be targets in the same batch');
    end;
    i := -1;
    if lRevision <> UIntToStr(wbGlobalModifedGeneration) then
      raise xeAutomationNewError('stale_revision', 'Loaded plugin revision changed during row preflight');
  except
    on E: Exception do begin
      lFailure := xeAutomationMutationFailure(E, xeAutomationErrorInvalidTarget, 'row-preflight', lSnapshot, nil);
      lFailure.Details.I['index'] := i;
      raise lFailure;
    end;
  end;

  Result := TJsonObject.Create;
  try
    Result.B['dryRun'] := lDryRun;
    Result.S['persistence'] := 'in-memory-until-session.save-then-terminal-session.flush';
    Result.I['total'] := lItems.Count;
    Result.I['completed'] := 0;
    // Pin interfaces throughout the batch: removing/sorting an earlier sibling
    // must not redirect a later item to whichever row now occupies its old path.
    for i := 0 to High(lTargets) do begin
      lEntry := Result.A['items'].AddObject;
      lEntry.I['index'] := i;
      lEntry.S['mode'] := lTargets[i].Mode;
      xeAutomationRowWriteLocator(lEntry.O['target'], lTargets[i].RecordRef, lTargets[i].ElementRef);
      if Assigned(lTargets[i].SourceRef) then
        xeAutomationRowWriteLocator(lEntry.O['source'], lTargets[i].SourceRecord, lTargets[i].SourceRef);
      for lMaster in lTargets[i].RequiredMasters do lEntry.A['requiredMasters'].Add(lMaster.FileName);
      lEntry.A['addedMasters'].Clear;
      if lDryRun then lEntry.S['outcome'] := 'planned'
      else lEntry.S['outcome'] := 'not-attempted';
    end;
    xeAutomationRequireBatchResponseBudget(Result);
    if not lDryRun then
      for i := 0 to High(lTargets) do begin
        lEntry := Result.A['items'].O[i];
        try
          // Native callbacks may remove other rows. A retained interface is
          // stable identity, but it must still belong to its original record.
          if not xeAutomationRowContains(lTargets[i].RecordRef, lTargets[i].ElementRef) then
            raise xeAutomationStateConflict('A planned row was detached by an earlier native mutation');
          if lTargets[i].Mode = 'remove' then
            xeAutomationRequireRemovableElementTarget(lTargets[i].ElementRef)
          else if lTargets[i].Mode = 'append' then
            xeAutomationRequireCopyTargetAt(lTargets[i].ElementRef, lTargets[i].SourceRef, wbAssignAdd)
          else
            xeAutomationRequireCopyTargetAt(lTargets[i].ElementRef, lTargets[i].SourceRef, wbAssignThis);
          for lMaster in lTargets[i].RequiredMasters do
            if not lTargets[i].RecordRef._File.HasMaster(lMaster.FileName) then begin
              lTargets[i].RecordRef._File.AddMasterIfMissing(lMaster.FileName, True, True);
              lEntry.A['addedMasters'].Add(lMaster.FileName);
            end;
          lNewElement := nil;
          if lTargets[i].Mode = 'remove' then
            lTargets[i].ElementRef.Remove
          else if lTargets[i].Mode = 'append' then begin
            lContainer := lTargets[i].ElementRef as IwbContainer;
            lCount := lContainer.ElementCount;
            lNewElement := wbAutomationAssign(lTargets[i].ElementRef, wbAssignAdd, lTargets[i].SourceRef);
            if not Assigned(lNewElement) or (lContainer.ElementCount <> lCount + 1) then
              raise xeAutomationMutationNotAllowed('Native row append did not create exactly one entry');
          end else begin
            // Bulk native replacement can return nil after successfully replacing
            // its children. The addressed row remains the replacement target.
            lNewElement := wbAutomationAssign(lTargets[i].ElementRef, wbAssignThis, lTargets[i].SourceRef);
            if not Assigned(lNewElement) then lNewElement := lTargets[i].ElementRef;
          end;
          lEntry.B['rowApplied'] := True;
          lTargets[i].RecordRef.UpdateRefs;
          if Assigned(lNewElement) then
            xeAutomationRowWriteLocator(lEntry.O['resultLocator'], lTargets[i].RecordRef, lNewElement);
          lEntry.S['outcome'] := 'applied';
          lEntry.B['pathsInvalidated'] := True;
          Result.I['completed'] := i + 1;
        except
          on E: Exception do begin
            lEntry.S['outcome'] := 'failed';
            lFailure := xeAutomationMutationFailure(E, xeAutomationErrorInternalError, 'row-apply', lSnapshot, nil);
            try
              Result.O['failure'].S['code'] := lFailure.Code;
              Result.O['failure'].S['message'] := lFailure.Message;
              Result.O['failure'].O['details'].Assign(lFailure.Details);
              Result.O['failure'].I['index'] := i;
              Result.O['failure'].I['notAttempted'] := lItems.Count - i - 1;
            finally
              lFailure.Free;
            end;
            // A native setter may throw after writing. Refresh references even
            // on that path; keep its failure separate from the original error.
            try
              lTargets[i].RecordRef.UpdateRefs;
            except
              on ERefresh: Exception do
                Result.O['failure'].S['referenceRefreshError'] := ERefresh.Message;
            end;
            Break;
          end;
        end;
      end;
    Result.B['complete'] := not Result.Contains('failure');
    Result.S['mutationRevision'] := UIntToStr(wbGlobalModifedGeneration);
    xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
    Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
    Result.B['pathsInvalidated'] := not lDryRun;
  except
    Result.Free;
    raise;
  end;
end;

procedure xeAutomationRegisterBatchCommands;
begin
  xeAutomationRegisterCommand('batch.read', xeAutomationBatchRead);
  xeAutomationRegisterCommand('batch.edit', xeAutomationBatchEdit);
  xeAutomationRegisterCommand('batch.rows', xeAutomationBatchRows);
end;

end.
