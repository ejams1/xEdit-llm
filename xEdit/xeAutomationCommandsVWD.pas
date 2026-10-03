{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsVWD;
interface
procedure xeAutomationRegisterVWDCommands;
implementation
uses Classes, SysUtils, System.Generics.Collections, JsonDataObjects, wbInterface,
  xeAutomationDataLookup, xeAutomationObjectModel, xeAutomationErrors,
  xeAutomationRegistry, xeAutomationMutationPolicy, xeAutomationMutationAudit;

function Exterior(element: IwbElement): Boolean;
var group: IwbGroupRecord; depth: Integer;
begin
  Result := False;
  // Use native ancestor group semantics, including world persistent cells.
  for depth := 0 to 64 do begin
    if not Assigned(element) then Exit;
    if Supports(element, IwbGroupRecord, group) then
      case group.GroupType of
        0: Exit(TwbSignature(group.GroupLabel) = 'WRLD');
        1, 4, 5: Exit(True);
        2, 3: Exit(False);
      end;
    element := element.Container;
  end;
  raise xeAutomationNewError('vwd_capacity', 'Reference ancestry exceeds 64 levels');
end;

function CopyArgs(const source: IwbMainRecord; const target: IwbFile; dry: Boolean): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.O['source'].S['file'] := source._File.FileName;
  Result.O['source'].S['formId'] := source.LoadOrderFormID.ToString(False);
  Result.O['target'].S['file'] := target.FileName;
  Result.S['mode'] := 'override';
  Result.B['dryRun'] := dry;
  Result.B['deepCopy'] := False;
  Result.B['overwrite'] := False;
  Result.B['addRequiredMasters'] := True;
end;

function SetFromMesh(const args: TJsonObject): TJsonObject;
var
  files: TJsonArray; names: TStringList; fileRef, target: IwbFile;
  recordRef, base, copied: IwbMainRecord; link: IwbElement;
  records: TList<IwbMainRecord>; candidates: TList<Integer>;
  byID: TDictionary<Cardinal, Integer>; row, copyRequest, copyResult: TJsonObject;
  dry, specified: Boolean; denied, reason: string;
  i, j, index, scanned: Integer; snapshot: TxeAutomationMutationSnapshot;
begin
  if not wbIsOblivion then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Native automatic VWD mesh discovery requires Oblivion definitions');
  if wbTranslationMode then raise xeAutomationMutationNotAllowed('Automatic VWD is unavailable in translation mode');
  if not Assigned(wbContainerHandler) then raise xeAutomationInvalidTarget('Native resource container is unavailable');
  if not args.Contains('files') or (args.Types['files'] <> jdtArray) then raise xeAutomationInvalidRequest('files must be a bounded loaded plugin array');
  files := args.A['files'];
  if (files.Count < 1) or (files.Count > 8) then raise xeAutomationInvalidRequest('Select 1..8 files');
  dry := xeAutomationReadBooleanArg(args, 'dryRun', specified); if not specified then dry := True;
  if not dry and not xeAutomationMutationPolicyConsentSatisfied(denied) then Exit(xeAutomationErrorsBuildConsentRequired('records.set_vwd_from_mesh', 'plugin-mutation', denied));
  target := nil;
  if args.Contains('targetFile') then begin
    target := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(args, 'targetFile'));
    xeAutomationRequireWritableTargetFile(target);
  end;
  records := TList<IwbMainRecord>.Create; candidates := TList<Integer>.Create;
  byID := TDictionary<Cardinal, Integer>.Create; names := TStringList.Create;
  Result := TJsonObject.Create;
  try
    try
      scanned := 0;
      for i := 0 to files.Count - 1 do begin
        if files.Types[i] <> jdtString then raise xeAutomationInvalidRequest('File entries must be plugin names');
        fileRef := xeAutomationRequirePluginFile(Trim(files.S[i]));
        if names.IndexOf(fileRef.FileName) >= 0 then raise xeAutomationInvalidRequest('Duplicate source file');
        names.Add(fileRef.FileName);
        Inc(scanned, fileRef.RecordCount);
        if scanned > 1000 then raise xeAutomationNewError('vwd_capacity', 'Automatic VWD scans at most 1000 source records');
        for j := 0 to fileRef.RecordCount - 1 do begin
          if not Supports(fileRef.Records[j], IwbMainRecord, recordRef) or (recordRef.Signature <> 'REFR') then Continue;
          if Assigned(target) and byID.TryGetValue(recordRef.LoadOrderFormID.ToCardinal, index) then begin
            // Native override action deduplicates selected identities, choosing
            // the latest selected version; it does not silently widen to winners.
            if recordRef._File.LoadOrder > records[index]._File.LoadOrder then records[index] := recordRef;
          end else begin
            if Assigned(target) then byID.Add(recordRef.LoadOrderFormID.ToCardinal, records.Count);
            records.Add(recordRef);
          end;
        end;
      end;
      Result.B['dryRun'] := dry; Result.B['complete'] := False;
      Result.I['scannedRecords'] := scanned; Result.I['planned'] := 0; Result.I['applied'] := 0;
      Result.S['persistence'] := 'in-memory flags/copies/masters; explicit session.save + terminal session.flush';
      Result.S['resourceState'] := 'native per-base cached resource existence; prepare VFS resources before launch';
      Result.A['records'].Clear;
      // Eligibility and every writable/copy/master predicate finish before the
      // first flag or target dependency changes. Existing target overrides refuse.
      for i := 0 to records.Count - 1 do begin
        recordRef := records[i]; base := nil;
        row := Result.A['records'].AddObject;
        row.S['file'] := recordRef._File.FileName;
        row.S['formId'] := recordRef.LoadOrderFormID.ToString(False);
        row.S['editorId'] := recordRef.EditorID;
        reason := '';
        if recordRef.IsVisibleWhenDistant then reason := 'already-vwd'
        else if not Exterior(recordRef) then reason := 'interior'
        else begin
          link := recordRef.RecordBySignature['NAME'];
          if not Assigned(link) or not Supports(link.LinksTo, IwbMainRecord, base) then reason := 'missing-base'
          else if not base.HasVisibleWhenDistantMesh then reason := 'no-vwd-resource'
          else if Assigned(target) and recordRef.HasErrors then reason := 'source-has-native-errors';
        end;
        row.B['eligible'] := reason = '';
        if reason <> '' then begin row.S['skipReason'] := reason; Continue; end;
        if Assigned(target) then begin
          if recordRef._File.LoadOrder >= target.LoadOrder then raise xeAutomationInvalidTarget('Override target must load after every eligible selected source');
          copyRequest := CopyArgs(recordRef, target, True);
          try
            copyResult := xeAutomationExecuteCommand('records.copy_into', copyRequest);
            try row.O['copyPlan'].Assign(copyResult); finally copyResult.Free; end;
          finally copyRequest.Free; end;
        end else xeAutomationRequireWritableRootRecordTarget(recordRef);
        if candidates.Count >= 128 then raise xeAutomationNewError('vwd_capacity', 'Apply plans at most 128 eligible references');
        candidates.Add(i);
      end;
      Result.I['planned'] := candidates.Count;
      if dry then begin Result.B['complete'] := True; Exit; end;
      snapshot := xeAutomationCaptureMutationSnapshot;
      try
        for index in candidates do begin
          recordRef := records[index]; row := Result.A['records'].O[index];
          if Assigned(target) then begin
            copyRequest := CopyArgs(recordRef, target, False);
            try
              copyResult := xeAutomationExecuteCommand('records.copy_into', copyRequest);
              try
                row.O['copyOutcome'].Assign(copyResult);
                copied := xeAutomationResolveOwnedMainRecordInFile(target, copyResult.O['locator'].S['formId']);
                if not Assigned(copied) then raise xeAutomationInvalidTarget('Native copy did not return a target-owned record');
              finally copyResult.Free; end;
            finally copyRequest.Free; end;
          end else copied := recordRef;
          copied.IsVisibleWhenDistant := True;
          if not copied.IsVisibleWhenDistant then raise xeAutomationStateConflict('Native flag readback differs after write');
          row.B['applied'] := True; row.S['targetFile'] := copied._File.FileName;
          Result.I['applied'] := Result.I['applied'] + 1;
        end;
        Result.B['complete'] := True;
      except
        on E: Exception do begin
          Result.O['failure'].S['message'] := E.Message;
          Result.O['failure'].I['completedRecords'] := Result.I['applied'];
          Result.O['failure'].B['rollbackComplete'] := False;
          if (E is ExeAutomationError) and Assigned(ExeAutomationError(E).Details) then Result.O['failure'].O['details'].Assign(ExeAutomationError(E).Details);
        end;
      end;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], snapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
    except Result.Free; raise; end;
  finally names.Free; byID.Free; candidates.Free; records.Free; end;
end;

procedure xeAutomationRegisterVWDCommands;
begin xeAutomationRegisterCommand('records.set_vwd_from_mesh', SetFromMesh); end;
end.
