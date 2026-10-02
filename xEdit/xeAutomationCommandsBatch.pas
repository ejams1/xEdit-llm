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
              SameText(lCommand, 'elements.get_value') or SameText(lCommand, 'elements.children')) then
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
      lValue := xeAutomationExecuteCommand(lCommand, lArgs);
      try
        xeAutomationProjectResponse(lValue, lArgs);
        lEntry := Result.A['items'].AddObject;
        lEntry.I['index'] := i;
        lEntry.S['command'] := lCommand;
        lEntry.O['result'] := lValue;
        lValue := nil;
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

procedure xeAutomationRegisterBatchCommands;
begin
  xeAutomationRegisterCommand('batch.read', xeAutomationBatchRead);
  xeAutomationRegisterCommand('batch.edit', xeAutomationBatchEdit);
end;

end.
