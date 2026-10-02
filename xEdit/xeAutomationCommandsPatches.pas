{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationCommandsPatches;

interface

procedure xeAutomationRegisterPatchCommands;

implementation

uses
  Windows, Classes, SysUtils, JsonDataObjects, wbInterface, wbImplementation,
  xeAutomationDataLookup, xeAutomationErrors, xeAutomationMutationAudit,
  xeAutomationMutationPolicy, xeAutomationObjectModel, xeAutomationRecordQueries,
  xeAutomationRegistry, xeAutomationMergedPatch, xeMainForm;

const
  MaxDeltaRecords = 1000;
  MaxDeltaInputBytes = 64 * 1024 * 1024;

function xeDeltaBoolean(const AArgs: TJsonObject; const AName: string;
  const ADefault: Boolean): Boolean;
var
  lSpecified: Boolean;
begin
  Result := xeAutomationReadBooleanArg(AArgs, AName, lSpecified);
  if not lSpecified then Result := ADefault;
end;

function xeDeltaIdentical(const ASource, ADelta: IwbMainRecord): Boolean;
var
  i: Integer;
begin
  Result := False;
  if not Assigned(ASource) or not Assigned(ADelta) or
     (ASource.Signature <> ADelta.Signature) or
     (ASource.Flags._Flags <> ADelta.Flags._Flags) or
     ASource.Modified or ADelta.Modified then Exit;
  // ContentEquals compares stored bytes. They are meaningful only when every
  // file-local slot has the same identity; the delta appends its baseline last.
  // Different master tables conservatively retain records for manual review.
  if ADelta._File.MasterCount[True] <> ASource._File.MasterCount[True] + 1 then Exit;
  for i := 0 to ASource._File.MasterCount[True] - 1 do
    if not ASource._File.Masters[i, True].Equals(ADelta._File.Masters[i, True]) then Exit;
  if not ADelta._File.Masters[ASource._File.MasterCount[True], True].Equals(ASource._File) then Exit;
  Result := ASource.ContentEquals(ADelta);
end;

procedure xeDeltaRemoveIdentical(const ASource, ADelta: IwbFile;
  out ARemoved, ASkipped: Integer);
var
  lRecords: TArray<IwbMainRecord>;
  lRecord, lBaseline: IwbMainRecord;
  lGroup: IwbGroupRecord;
  lContainer, lParent: IwbContainerElementRef;
  i: Integer;
  lRemovedAny: Boolean;
begin
  ARemoved := 0;
  repeat
    ASkipped := 0;
    lRemovedAny := False;
    SetLength(lRecords, ADelta.RecordCount);
    for i := 0 to ADelta.RecordCount - 1 do lRecords[i] := ADelta.Records[i];
    for i := High(lRecords) downto Low(lRecords) do begin
      lRecord := lRecords[i];
      if lRecord.Signature = 'TES4' then Continue;
      lBaseline := xeAutomationResolveOwnedMainRecordInFile(ASource, lRecord.LoadOrderFormID.ToString(False));
      if not xeDeltaIdentical(lBaseline, lRecord) then Continue;
      // Like native delta cleanup, retain ancestors of surviving children and
      // retry parents after child removal. Never compare with MasterOrSelf:
      // a newer version can intentionally revert the oldest master's values.
      lGroup := lRecord.ChildGroup;
      if Assigned(lGroup) and (lGroup.ElementCount = 0) then begin
        lGroup.Remove;
        lGroup := nil;
      end;
      if Assigned(lGroup) or not lRecord.IsRemovable then begin
        Inc(ASkipped);
        Continue;
      end;
      lContainer := lRecord.Container as IwbContainerElementRef;
      lRecord.Remove;
      Inc(ARemoved);
      lRemovedAny := True;
      while Assigned(lContainer) and (lContainer.ElementCount = 0) do begin
        lParent := lContainer.Container as IwbContainerElementRef;
        lContainer.Remove;
        lContainer := lParent;
      end;
    end;
  until not lRemovedAny;
end;

procedure xeDeltaCheckInput(const APath: string);
var
  lStream: TFileStream;
  lHeader: array[0..23] of Byte;
  lPayload: TBytes;
  lSize, lCount: Cardinal;
  lSubSize: Word;
  lOffset, lHeaderSize: Integer;
  lFound: Boolean;
begin
  // Validate the declared record budget without loading a comparison into the
  // live master chain. The real native parser remains authoritative on apply.
  lStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    lHeaderSize := SizeOf(lHeader);
    if wbGameMode = gmTES4 then lHeaderSize := 20;
    if (lStream.Size < lHeaderSize) or (lStream.Size > MaxDeltaInputBytes) then
      raise xeAutomationInvalidRequest('Delta comparison must have a complete header and be <=64 MiB');
    lStream.ReadBuffer(lHeader, lHeaderSize);
    if (lHeader[0] <> Ord('T')) or (lHeader[1] <> Ord('E')) or
       (lHeader[2] <> Ord('S')) or (lHeader[3] <> Ord('4')) then
      raise xeAutomationInvalidTarget('Delta comparison must have a TES4 plugin header');
    Move(lHeader[4], lSize, SizeOf(lSize));
    if (lSize > 1048576) or (lSize > lStream.Size - lHeaderSize) then
      raise xeAutomationInvalidTarget('Delta comparison header is malformed or exceeds 1 MiB');
    SetLength(lPayload, lSize);
    if lSize > 0 then lStream.ReadBuffer(lPayload[0], lSize);
    lOffset := 0;
    lFound := False;
    while lOffset + 6 <= Length(lPayload) do begin
      Move(lPayload[lOffset + 4], lSubSize, SizeOf(lSubSize));
      if lOffset + 6 + lSubSize > Length(lPayload) then
        raise xeAutomationInvalidTarget('Delta comparison header subrecord exceeds payload');
      if (lPayload[lOffset] = Ord('H')) and (lPayload[lOffset + 1] = Ord('E')) and
         (lPayload[lOffset + 2] = Ord('D')) and (lPayload[lOffset + 3] = Ord('R')) then begin
        if lSubSize <> 12 then raise xeAutomationInvalidTarget('Invalid HEDR size');
        Move(lPayload[lOffset + 10], lCount, SizeOf(lCount));
        if lCount > MaxDeltaRecords then
          raise xeAutomationNewError('patch_capacity', 'Comparison declares more than 1000 records');
        lFound := True;
      end;
      Inc(lOffset, 6 + lSubSize);
    end;
    if not lFound or (lOffset <> Length(lPayload)) then
      raise xeAutomationInvalidTarget('Delta comparison header has no valid HEDR');
  finally
    lStream.Free;
  end;
end;

function xeAutomationDeltaPatch(const AArgs: TJsonObject): TJsonObject;
var
  lSource, lDelta, lMaster: IwbFile;
  lSourceRecords: TArray<IwbMainRecord>;
  lRecord, lCopied, lBaseline: IwbMainRecord;
  lElement: IwbElement;
  lComparePath, lOutputName, lOutputPath, lDenied, lPhase: string;
  lMasters: TStringList;
  lDryRun, lMarkRemoved, lClean, lLocalized: Boolean;
  lSnapshot: TxeAutomationMutationSnapshot;
  lOutcome: TJsonObject;
  i, lApplied, lSkipped: Integer;
begin
  if wbIsMorrowind then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Delta patches require numeric TES4 plugin records');
  if wbTranslationMode then
    raise xeAutomationMutationNotAllowed('Delta patches are unavailable in translation mode');
  lDryRun := xeDeltaBoolean(AArgs, 'dryRun', True);
  lMarkRemoved := xeDeltaBoolean(AArgs, 'markRemovedDeleted', True);
  lClean := xeDeltaBoolean(AArgs, 'removeIdentical', True);
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDenied) then
    Exit(xeAutomationErrorsBuildConsentRequired('patches.delta', 'patch-mutation-and-external-copy', lDenied));
  lSource := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'sourceFile'));
  if lSource.IsLocalized then
    raise xeAutomationInvalidTarget('Localized baselines require string-table copying and are unsupported');
  if lSource.Modified then
    raise xeAutomationStateConflict('Save/reload the delta baseline before comparing an external version');
  if lSource.RecordCount > MaxDeltaRecords then
    raise xeAutomationNewError('patch_capacity', 'Baseline has more than 1000 records');
  lComparePath := ExpandFileName(xeAutomationRequireStringArg(AArgs, 'comparePath'));
  if not FileExists(lComparePath) or not wbIsModule(lComparePath) then
    raise xeAutomationInvalidTarget('comparePath must identify an existing module');
  if FileExists(ChangeFileExt(lComparePath, '.cpoverride')) then
    raise xeAutomationInvalidTarget('Comparison encoding sidecars are unsupported; cloning changes their lookup name');
  lOutputName := xeAutomationRequireStringArg(AArgs, 'outputFile');
  if (Length(lOutputName) > 255) or
     (Pos('<', lOutputName) > 0) or (Pos('>', lOutputName) > 0) or
     (Pos('"', lOutputName) > 0) or (Pos('|', lOutputName) > 0) or
     (Pos('?', lOutputName) > 0) or (Pos('*', lOutputName) > 0) then
    raise xeAutomationInvalidRequest('outputFile contains invalid filename characters or exceeds 255 characters');
  if (ExtractFileName(lOutputName) <> lOutputName) or (Pos(':', lOutputName) > 0) or
     (Pos('..', lOutputName) > 0) or not SameText(ExtractFileExt(lOutputName), '.esu') then
    raise xeAutomationInvalidRequest('outputFile must be a simple new .esu filename');
  lOutputPath := IncludeTrailingPathDelimiter(wbDataPath) + lOutputName;
  if FileExists(lOutputPath) or Assigned(xeAutomationTryPluginFile(lOutputName)) then
    raise xeAutomationStateConflict('Delta output already exists on disk or in the session; choose another name');
  if not lDryRun and not wbEditAllowed then
    raise xeAutomationReadOnlyTarget('Delta apply requires edit mode');
  xeDeltaCheckInput(lComparePath);
  lMasters := TStringList.Create;
  try
    lLocalized := False;
    if not wbMastersForFile(lComparePath, lMasters, nil, nil, @lLocalized) then
      raise xeAutomationInvalidTarget('Native comparison header could not be read');
    if lLocalized then
      raise xeAutomationInvalidTarget('Localized comparisons require string-table copying and are unsupported');
    for i := 0 to lMasters.Count - 1 do begin
      lMaster := xeAutomationRequirePluginFile(lMasters[i]);
      if lMaster.LoadOrder >= lSource.LoadOrder then
        raise xeAutomationInvalidTarget('Comparison dependencies must be loaded before the baseline');
    end;
    SetLength(lSourceRecords, lSource.RecordCount);
    for i := 0 to lSource.RecordCount - 1 do lSourceRecords[i] := lSource.Records[i];
    lSnapshot := xeAutomationCaptureMutationSnapshot;
    Result := TJsonObject.Create;
    try
      Result.B['dryRun'] := lDryRun;
      Result.B['complete'] := False;
      Result.B['externalCopyCreated'] := False;
      Result.B['loaded'] := False;
      Result.S['sourceFile'] := lSource.FileName;
      Result.S['comparePath'] := lComparePath;
      Result.S['outputPath'] := lOutputPath;
      Result.S['persistence'] := 'apply-immediately-copies-comparison-to-disk; delta-edits-in-memory-until-session.save-and-flush';
      Result.S['comparisonPolicy'] := 'exact selected baseline; different file-local master mappings conservatively retain records';
      for i := 0 to lMasters.Count - 1 do Result.A['requiredMasters'].Add(lMasters[i]);
      Result.A['requiredMasters'].Add(lSource.FileName);
      Result.B['markRemovedDeleted'] := lMarkRemoved;
      Result.B['removeIdentical'] := lClean;
      Result.A['records'].Clear;
      Result.I['deletionMarkers'] := 0;
      if lDryRun then begin
        Result.B['complete'] := True;
        Result.B['changed'] := False;
        Result.B['recordOutcomesAvailable'] := False;
        Result.S['planNote'] := 'Header/dependency plan only; record outcomes require native comparison load on apply';
        Exit;
      end;
      lPhase := 'external-copy';
      try
        // The GUI creates a real .esu copy before loading it. Keep that disk
        // boundary explicit and fail if a racing writer already created it.
        if not CopyFile(PChar(lComparePath), PChar(lOutputPath), True) then RaiseLastOSError;
        Result.B['externalCopyCreated'] := True;
        lPhase := 'native-compare-load';
        lDelta := wbFile(lOutputPath, lSource.LoadOrder, lSource.FileName, [fsIsDeltaPatch]);
        if not Assigned(lDelta.CompareToFile) or not lDelta.CompareToFile.Equals(lSource) then
          raise xeAutomationInvalidTarget('Native delta load did not attach the requested baseline');
        if Assigned(frmMain) then frmMain.AddFile(lDelta);
        Result.B['loaded'] := True;
        if lDelta.RecordCount > MaxDeltaRecords then
          raise xeAutomationNewError('patch_capacity', 'Loaded comparison exceeds 1000 records');
        xeAutomationRequireWritableTargetFile(lDelta);
        lPhase := 'deletion-markers';
        if lMarkRemoved then
          for i := Low(lSourceRecords) to High(lSourceRecords) do begin
            lRecord := lSourceRecords[i];
            if (lRecord.Signature = 'TES4') or lRecord.IsDeleted then Continue;
            if Assigned(xeAutomationResolveOwnedMainRecordInFile(lDelta, lRecord.LoadOrderFormID.ToString(False))) then Continue;
            lElement := wbCopyElementToFile(lRecord, lDelta, False, False, '', '', '', '', False);
            if not Supports(lElement, IwbMainRecord, lCopied) or not lCopied._File.Equals(lDelta) then
              raise xeAutomationInvalidTarget('Native deletion-marker copy did not produce an owned delta record');
            lCopied.IsDeleted := True;
            Result.I['deletionMarkers'] := Result.I['deletionMarkers'] + 1;
          end;
        lPhase := 'identical-removal';
        if lClean then begin
          xeDeltaRemoveIdentical(lSource, lDelta, lApplied, lSkipped);
          Result.I['itmRemoved'] := lApplied;
          Result.I['itmSkipped'] := lSkipped;
        end;
        lPhase := 'record-outcomes';
        for i := 0 to lDelta.RecordCount - 1 do begin
          lRecord := lDelta.Records[i];
          if lRecord.Signature = 'TES4' then Continue;
          lOutcome := Result.A['records'].AddObject;
          lOutcome.S['file'] := lDelta.FileName;
          lOutcome.S['formId'] := lRecord.LoadOrderFormID.ToString(False);
          lOutcome.S['signature'] := lRecord.Signature;
          lBaseline := xeAutomationResolveOwnedMainRecordInFile(lSource, lRecord.LoadOrderFormID.ToString(False));
          if lRecord.IsDeleted then lOutcome.S['outcome'] := 'deleted'
          else if not Assigned(lBaseline) then lOutcome.S['outcome'] := 'new'
          else if xeDeltaIdentical(lBaseline, lRecord) then lOutcome.S['outcome'] := 'retained-identical'
          else lOutcome.S['outcome'] := 'changed';
        end;
        Result.I['retainedRecords'] := Result.A['records'].Count;
        Result.B['complete'] := True;
      except
        on E: Exception do begin
          if E is ExeAutomationError then Result.O['failure'].S['code'] := ExeAutomationError(E).Code
          else Result.O['failure'].S['code'] := xeAutomationErrorInternalError;
          Result.O['failure'].S['message'] := E.Message;
          Result.O['failure'].S['phase'] := lPhase;
          Result.O['failure'].B['partial'] := Result.B['externalCopyCreated'] or Assigned(lDelta);
          Result.O['failure'].B['partialKnown'] := lPhase <> 'external-copy';
          Result.O['failure'].S['remainingState'] := 'Inspect outputPath and loaded delta; disk copy may contain the full comparison until save';
        end;
      end;
      xeAutomationInvalidateRecordQueries;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
      Result.B['changed'] := Result.B['externalCopyCreated'] or Result.O['mutationState'].B['mutationsObserved'];
      Result.B['requiresSave'] := Assigned(lDelta) and lDelta.Modified;
      if Assigned(lDelta) then Result.S['outputFile'] := lDelta.FileName;
    except
      Result.Free;
      raise;
    end;
  finally
    lMasters.Free;
  end;
end;

procedure xeAutomationRegisterPatchCommands;
begin
  xeAutomationRegisterCommand('patches.delta', xeAutomationDeltaPatch);
  xeAutomationRegisterCommand('patches.merge', xeAutomationMergedPatchCommand);
end;

end.
