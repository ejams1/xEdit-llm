{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsVWD;
interface
procedure xeAutomationRegisterVWDCommands;
implementation
uses Classes, SysUtils, System.Generics.Collections, JsonDataObjects, wbInterface,
  xeAutomationDataLookup, xeAutomationObjectModel, xeAutomationErrors,
  xeAutomationRegistry, xeAutomationMutationPolicy, xeAutomationMutationAudit,
  xeAutomationRecordQueries;

function FlagGroup(Persistent, VWD: Boolean): Integer;
begin
  if Persistent then Result := 8
  else if VWD and not wbVWDInTemporary then Result := 10 else Result := 9;
end;

function ReferenceCell(const R: IwbMainRecord; out Group: IwbGroupRecord): IwbMainRecord;
var Children: IwbGroupRecord;
begin
  if not Supports(R.Container, IwbGroupRecord, Group) or not (Group.GroupType in [8,9,10]) or
     not Supports(Group.Container, IwbGroupRecord, Children) or (Children.GroupType <> 6) then
    raise xeAutomationInvalidTarget('REFR must belong to a native CELL child group');
  Result := Children.ChildrenOf;
  if not Assigned(Result) or (Result.Signature <> 'CELL') or not Result.ElementExists['DATA'] then
    raise xeAutomationInvalidTarget('Owning CELL must have complete DATA');
end;

function PlannedCell(const R: IwbMainRecord; Persistent, VWD: Boolean): IwbMainRecord;
var Group, Owner: IwbGroupRecord; World: IwbMainRecord; Position: TwbVector;
  Grid, CellGrid: TwbGridCell;
begin
  Result := ReferenceCell(R, Group);
  if (Integer(Result.GetElementNativeValue('DATA')) and 1) <> 0 then Exit;
  if not Supports(Result.Container, IwbGroupRecord, Owner) or not (Owner.GroupType in [1,5]) then
    raise xeAutomationInvalidTarget('Exterior CELL must have native world ancestry');
  World := Owner.ChildrenOf;
  if not Assigned(World) or (World.Signature <> 'WRLD') then
    raise xeAutomationInvalidTarget('Exterior CELL worldspace is unavailable');
  if Persistent then begin
    if Owner.GroupType = 1 then Exit;
    Result := xeAutomationFindPersistentWorldCell(World.ChildGroup);
  end else begin
    if not R.GetPosition(Position) then raise xeAutomationInvalidTarget('Exterior REFR position is unavailable');
    Grid := wbPositionToGridCell(Position);
    if not Result.IsPersistent and Result.GetGridCell(CellGrid) and (Grid = CellGrid) then Exit;
    Result := World.ChildByGridCell[Grid];
  end;
  // Deliberately require existing owned destination CELLs. Native Add would
  // otherwise create parents after flags change, with no all-target preflight.
  if not Assigned(Result) or not Result._File.Equals(R._File) or not Result.ElementExists['DATA'] then
    raise xeAutomationInvalidTarget('Create a complete target-owned destination CELL before changing exterior flags');
  xeAutomationRequireWritableRootRecordTarget(Result);
end;

function SetReferenceFlags(const Args: TJsonObject): TJsonObject;
var Records, Cells: TList<IwbMainRecord>; R, Cell: IwbMainRecord; Group: IwbGroupRecord;
  Item, Row: TJsonObject; Locator: TxeAutomationLocator; i: Integer;
  P, V, HasP, HasV, OldP, OldV, Expected, Present, Dry, Specified: Boolean;
  Denied, Revision: string; Snapshot: TxeAutomationMutationSnapshot;
begin
  if wbIsMorrowind or wbTranslationMode then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Reference flags require numeric edit-mode definitions');
  if not Args.Contains('records') or (Args.Types['records'] <> jdtArray) or
    (Args.A['records'].Count < 1) or (Args.A['records'].Count > 32) then
    raise xeAutomationInvalidRequest('records must contain 1..32 owned REFR locators');
  P := xeAutomationReadBooleanArg(Args, 'persistent', HasP);
  V := xeAutomationReadBooleanArg(Args, 'visibleWhenDistant', HasV);
  if not HasP and not HasV then raise xeAutomationInvalidRequest('Specify persistent and/or visibleWhenDistant');
  Dry := xeAutomationReadBooleanArg(Args, 'dryRun', Specified); if not Specified then Dry := True;
  if not Dry and not xeAutomationMutationPolicyConsentSatisfied(Denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('records.set_reference_flags', 'plugin-mutation', Denied));
  Revision := UIntToStr(wbGlobalModifedGeneration);
  if Args.Contains('expectedRevision') and (xeAutomationRequireStringArg(Args, 'expectedRevision') <> Revision) then
    raise xeAutomationNewError('stale_revision', 'Reference flags require the current mutation revision');
  Records := TList<IwbMainRecord>.Create; Cells := TList<IwbMainRecord>.Create;
  Result := TJsonObject.Create;
  try
    try
      Result.B['dryRun'] := Dry; Result.S['persistence'] := 'native flags and CELL child migration in memory; explicit save + terminal flush';
      Result.S['exteriorPolicy'] := 'existing complete target-owned destination CELLs only; no implicit CELL creation';
      for i := 0 to Args.A['records'].Count - 1 do begin
        if Args.A['records'].Types[i] <> jdtObject then raise xeAutomationInvalidRequest('Record entries must be locator objects');
        Item := Args.A['records'].O[i]; Locator := xeAutomationParseLocator(Item, True, False);
        if Locator.Path <> '' then raise xeAutomationInvalidRequest('Flags require record roots');
        R := xeAutomationRequireOwnedMainRecord(Locator);
        if Records.Contains(R) then raise xeAutomationInvalidRequest('Duplicate reference target');
        xeAutomationRequireWritableRootRecordTarget(R);
        if (R.Signature <> 'REFR') or R.IsDeleted or R.IsPartialForm then
          raise xeAutomationInvalidTarget('Flags require nondeleted complete native REFR records');
        OldP := R.IsPersistent; OldV := R.IsVisibleWhenDistant;
        Expected := xeAutomationReadBooleanArg(Item, 'expectedPersistent', Present);
        if Present and (Expected <> OldP) then raise xeAutomationNewError('stale_value', 'Persistent state changed');
        Expected := xeAutomationReadBooleanArg(Item, 'expectedVisibleWhenDistant', Present);
        if Present and (Expected <> OldV) then raise xeAutomationNewError('stale_value', 'VWD state changed');
        // Persistent is applied first; validate its intermediate destination as
        // well as the final one before any item in the batch changes.
        if HasP and (P <> OldP) then PlannedCell(R, P, OldV);
        if not HasP then P := OldP;
        if not HasV then V := OldV;
        Cell := PlannedCell(R, P, V); Records.Add(R); Cells.Add(Cell);
        Row := Result.A['records'].AddObject;
        Row.S['file'] := R._File.FileName; Row.S['formId'] := R.LoadOrderFormID.ToString(False);
        Row.B['persistentBefore'] := OldP; Row.B['visibleWhenDistantBefore'] := OldV;
        Row.B['persistentAfter'] := P; Row.B['visibleWhenDistantAfter'] := V;
        Row.I['plannedGroupType'] := FlagGroup(P,V);
        Row.S['plannedCell'] := Cell.LoadOrderFormID.ToString(False); Row.S['outcome'] := 'planned';
      end;
      Snapshot := xeAutomationCaptureMutationSnapshot;
      if not Dry then for i := 0 to Records.Count - 1 do begin
        R := Records[i]; Row := Result.A['records'].O[i];
        try
          R.IsPersistent := Row.B['persistentAfter'];
          R.IsVisibleWhenDistant := Row.B['visibleWhenDistantAfter'];
          Cell := ReferenceCell(R, Group);
          if not Cell.Equals(Cells[i]) or (Group.GroupType <> Row.I['plannedGroupType']) or
            (R.IsPersistent <> Row.B['persistentAfter']) or (R.IsVisibleWhenDistant <> Row.B['visibleWhenDistantAfter']) then
            raise xeAutomationStateConflict('Native flag/CELL migration readback differs from the plan');
          Row.I['actualGroupType'] := Group.GroupType; Row.S['actualCell'] := Cell.LoadOrderFormID.ToString(False);
          Row.S['outcome'] := 'applied';
        except on E: Exception do begin
          Row.S['outcome'] := 'failed'; Result.O['failure'].S['code'] := 'reference_flags_failed';
          Result.O['failure'].S['message'] := E.Message; Result.O['failure'].I['index'] := i; Break;
        end; end;
      end;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], Snapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      Result.B['complete'] := not Result.Contains('failure'); Result.B['partial'] := not Result.B['complete'] and Result.B['changed'];
      Result.B['requiresSave'] := Result.B['changed']; Result.B['pathInvalidated'] := Result.B['changed'];
      if Result.B['changed'] then xeAutomationInvalidateRecordQueries;
    except Result.Free; raise; end;
  finally Cells.Free; Records.Free; end;
end;

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
begin
  xeAutomationRegisterCommand('records.set_vwd_from_mesh', SetFromMesh);
  xeAutomationRegisterCommand('records.set_reference_flags', SetReferenceFlags);
end;
end.
