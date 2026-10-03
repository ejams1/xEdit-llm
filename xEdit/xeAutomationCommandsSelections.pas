{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsSelections;
interface
procedure xeAutomationRegisterSelectionCommands;
implementation
uses Classes, SysUtils, System.Generics.Collections, JsonDataObjects,
  wbInterface, wbImplementation, xeAutomationDataLookup, xeAutomationObjectModel,
  xeAutomationErrors, xeAutomationRegistry, xeAutomationMutationPolicy,
  xeAutomationMutationAudit;

procedure RequireMode;
begin
  if (wbGameMode = gmTES3) or wbTranslationMode then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'File/group selections require non-TES3 plugin definitions and translation mode off');
end;

function GroupPath(const element: IwbElement): TJsonArray;
var chain: TList<IwbGroupRecord>; parent: IwbElement; group: IwbGroupRecord; i: Integer;
begin
  chain := TList<IwbGroupRecord>.Create;
  Result := TJsonArray.Create;
  try
    try
    parent := element;
    while Assigned(parent) do begin
      if Supports(parent, IwbGroupRecord, group) then begin
        if chain.Count >= 8 then raise xeAutomationNewError('selection_capacity', 'Native group selector exceeds depth 8');
        chain.Add(group);
      end;
      parent := parent.Container;
    end;
    for i := chain.Count - 1 downto 0 do begin
      Result.AddObject.I['type'] := chain[i].GroupType;
      Result.O[Result.Count - 1].S['label'] := IntToHex(chain[i].GroupLabel, 8);
    end;
    except Result.Free; raise; end;
  finally chain.Free; end;
end;

function Resolve(const selector: TJsonObject; var visits: Integer): IwbElement;
var fileRef: IwbFile; container: IwbContainerElementRef; group, found: IwbGroupRecord;
  path: TJsonArray; labelValue: Cardinal; typeValue, i, j, k: Integer; kind: string;
begin
  fileRef := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(selector, 'file'));
  kind := LowerCase(xeAutomationRequireStringArg(selector, 'kind'));
  for k := 0 to selector.Count - 1 do
    if (selector.Names[k] <> 'file') and (selector.Names[k] <> 'kind') and
       (selector.Names[k] <> 'groupPath') then raise xeAutomationInvalidRequest('Unknown selection field');
  Result := fileRef;
  if kind = 'file' then begin
    if selector.Contains('groupPath') then raise xeAutomationInvalidRequest('File selections do not have groupPath');
    Exit;
  end;
  if (kind <> 'group') or not selector.Contains('groupPath') or
     (selector.Types['groupPath'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Group selections need groupPath from selections.inspect');
  path := selector.A['groupPath'];
  if (path.Count < 1) or (path.Count > 8) then raise xeAutomationInvalidRequest('groupPath must have 1..8 native group steps');
  for i := 0 to path.Count - 1 do begin
    if path.Types[i] <> jdtObject then raise xeAutomationInvalidRequest('groupPath steps must be objects');
    if (path.O[i].Count <> 2) or not path.O[i].Contains('type') or
       not (path.O[i].Types['type'] in [jdtInt, jdtLong]) or
       not path.O[i].Contains('label') or (path.O[i].Types['label'] <> jdtString) then
      raise xeAutomationInvalidRequest('Group steps require integer type and eight-hex-digit label');
    if (path.O[i].L['type'] < 0) or (path.O[i].L['type'] > 10) then
      raise xeAutomationInvalidRequest('Native group type must be 0..10');
    typeValue := path.O[i].I['type'];
    if Length(path.O[i].S['label']) <> 8 then raise xeAutomationInvalidRequest('Group labels require exactly eight hex digits');
    for k := 1 to 8 do if not CharInSet(path.O[i].S['label'][k], ['0'..'9', 'a'..'f', 'A'..'F']) then
      raise xeAutomationInvalidRequest('Group labels require exactly eight hex digits');
    labelValue := xeAutomationParseFormIdHex(path.O[i].S['label']);
    if not Supports(Result, IwbContainerElementRef, container) then raise xeAutomationInvalidTarget('Group path parent is unavailable');
    if container.ElementCount > 2048 then raise xeAutomationNewError('selection_capacity', 'Group path sibling search exceeds 2048 nodes');
    found := nil;
    // Labels are current native labels, not persistent disk IDs; get fresh
    // paths after a master edit/reload. Lazy groups initialize during traversal.
    for j := 0 to container.ElementCount - 1 do begin
      Inc(visits);
      if visits > 2048 then raise xeAutomationNewError('selection_capacity', 'Combined group path resolution exceeds 2048 sibling visits');
      if Supports(container.Elements[j], IwbGroupRecord, group) and
         (group.GroupType = typeValue) and (group.GroupLabel = labelValue) then begin
        if Assigned(found) then raise xeAutomationStateConflict('Ambiguous group path');
        found := group;
      end;
    end;
    if not Assigned(found) then raise xeAutomationInvalidTarget('Native group path not found');
    Result := found;
  end;
end;

function ContainsElement(const ancestor, element: IwbElement): Boolean;
var current: IwbElement;
begin
  current := element;
  while Assigned(current) do begin
    if current.Equals(ancestor) then Exit(True);
    current := current.Container;
  end;
  Result := False;
end;

procedure Collect(const element: IwbElement; const nodes: TList<IwbElement>;
  const records: TList<IwbMainRecord>; depth: Integer);
var container: IwbContainerElementRef; recordRef: IwbMainRecord; i: Integer;
begin
  if (depth > 8) or (nodes.Count >= 2048) then raise xeAutomationNewError('selection_capacity', 'Selection exceeds 2048 nodes or depth 8');
  for i := 0 to nodes.Count - 1 do if nodes[i].Equals(element) then Exit;
  nodes.Add(element);
  if Supports(element, IwbMainRecord, recordRef) then begin
    if recordRef.Signature = 'TES4' then Exit;
    if records.Count >= 128 then raise xeAutomationNewError('selection_capacity', 'Selection exceeds 128 records');
    records.Add(recordRef);
    // MainRecord.Elements are payload fields; ChildGroup is traversed through
    // its structural container separately, avoiding unbounded value subtrees.
    Exit;
  end;
  if Supports(element, IwbContainerElementRef, container) then
    for i := 0 to container.ElementCount - 1 do Collect(container.Elements[i], nodes, records, depth + 1);
end;

procedure ReadSelections(const args: TJsonObject; const selected, nodes: TList<IwbElement>;
  const records: TList<IwbMainRecord>);
var inputs: TJsonArray; element: IwbElement; i, j, visits: Integer;
begin
  RequireMode;
  if not args.Contains('selections') or (args.Types['selections'] <> jdtArray) then
    raise xeAutomationInvalidRequest('selections must be an array');
  inputs := args.A['selections'];
  if (inputs.Count < 1) or (inputs.Count > 16) then raise xeAutomationInvalidRequest('Select 1..16 file/group containers');
  visits := 0;
  for i := 0 to inputs.Count - 1 do begin
    if inputs.Types[i] <> jdtObject then raise xeAutomationInvalidRequest('Selections must be objects');
    element := Resolve(inputs.O[i], visits);
    for j := 0 to selected.Count - 1 do
      if ContainsElement(selected[j], element) or ContainsElement(element, selected[j]) then
        raise xeAutomationInvalidRequest('Duplicate or overlapping selections');
    selected.Add(element);
    Collect(element, nodes, records, 0);
  end;
end;

procedure Identity(const row: TJsonObject; const recordRef: IwbMainRecord);
begin
  row.S['file'] := recordRef._File.FileName;
  row.S['formId'] := recordRef.LoadOrderFormID.ToString(False); row.S['path'] := '';
end;

function Inspect(const args: TJsonObject): TJsonObject;
var selected, nodes: TList<IwbElement>; records: TList<IwbMainRecord>;
  group: IwbGroupRecord; row: TJsonObject; i: Integer;
begin
  selected := TList<IwbElement>.Create; nodes := TList<IwbElement>.Create;
  records := TList<IwbMainRecord>.Create;
  Result := TJsonObject.Create;
  try
    try
      ReadSelections(args, selected, nodes, records);
      Result.A['groups'].Clear; Result.A['records'].Clear;
      for i := 0 to nodes.Count - 1 do if Supports(nodes[i], IwbGroupRecord, group) then begin
        row := Result.A['groups'].AddObject;
        row.O['selector'].S['kind'] := 'group'; row.O['selector'].S['file'] := group._File.FileName;
        row.O['selector'].A['groupPath'] := GroupPath(group);
        row.I['elementCount'] := group.ElementCount;
        row.B['canCopy'] := group.CanCopy; row.B['isRemovable'] := group.IsRemovable;
      end;
      for i := 0 to records.Count - 1 do Identity(Result.A['records'].AddObject, records[i]);
      Result.B['complete'] := True;
      Result.S['revision'] := UIntToStr(wbGlobalModifedGeneration);
      Result.S['pathScope'] := 'current session native labels; re-inspect after master edits/reload';
      Result.S['fileRemoval'] := 'unsupported: native files are not removable; restart with a different plugin list to unload; no disk deletion';
    except Result.Free; raise; end;
  finally records.Free; nodes.Free; selected.Free; end;
end;

procedure OrderWithOwners(const records: TList<IwbMainRecord>; const target: IwbFile);
var ordered: TList<IwbMainRecord>; originals: TArray<IwbMainRecord>; recordRef: IwbMainRecord;

  procedure Add(const current: IwbMainRecord; depth: Integer);
  var container: IwbContainer; group: IwbGroupRecord; owner, selectedOwner, existing: IwbMainRecord; i: Integer;
  begin
    if depth > 8 then raise xeAutomationNewError('selection_capacity', 'Owner ancestry exceeds depth 8');
    for i := 0 to ordered.Count - 1 do
      if ordered[i].LoadOrderFormID = current.LoadOrderFormID then begin
        if not ordered[i].Equals(current) then raise xeAutomationInvalidRequest('Ambiguous source owner versions');
        Exit;
      end;
    if current.IsPartialForm or current.IsDeleted then
      raise xeAutomationMutationNotAllowed('Selection payload copying excludes partial/deleted records; use explicit root copy for native partial/deleted semantics');
    container := current.Container;
    while Assigned(container) do begin
      if Supports(container, IwbGroupRecord, group) then begin
        owner := group.ChildrenOf;
        if Assigned(owner) then begin
          if owner.LoadOrderFormID = current.LoadOrderFormID then raise xeAutomationInvalidTarget('Circular owner ancestry');
          selectedOwner := nil;
          for i := 0 to Length(originals) - 1 do
            if originals[i].LoadOrderFormID = owner.LoadOrderFormID then begin
              if Assigned(selectedOwner) and not selectedOwner.Equals(originals[i]) then
                raise xeAutomationInvalidRequest('Multiple selected owner versions');
              selectedOwner := originals[i];
            end;
          existing := xeAutomationResolveOwnedMainRecordInFile(target, owner.LoadOrderFormID.ToString(False));
          if Assigned(selectedOwner) then Add(selectedOwner, depth + 1)
          else if Assigned(existing) then xeAutomationRequireWritableRootRecordTarget(existing)
          else begin
            owner := owner.HighestOverrideVisibleForFile[target];
            if not Assigned(owner) then raise xeAutomationInvalidTarget('Native implicit owner is unavailable');
            Add(owner, depth + 1);
          end;
        end;
      end;
      container := container.Container;
    end;
    if ordered.Count >= 128 then raise xeAutomationNewError('selection_capacity', 'Selection and implicit owners exceed 128 records');
    ordered.Add(current);
  end;

begin
  ordered := TList<IwbMainRecord>.Create;
  try
    originals := records.ToArray;
    // Native contextual group copies may clone owners outside the selected
    // subtree. Include their exact visible versions/payload dependencies and
    // budgets before any write; selected explicit owner versions take priority.
    for recordRef in originals do Add(recordRef, 0);
    records.Clear;
    for recordRef in ordered do records.Add(recordRef);
  finally ordered.Free; end;
end;

function CopyInto(const args: TJsonObject): TJsonObject;
var selected, nodes: TList<IwbElement>; records: TList<IwbMainRecord>;
  calls: TObjectList<TJsonObject>; call, response, row: TJsonObject;
  target: IwbFile; dry, overwrite, addMasters, specified: Boolean;
  denied: string; snapshot: TxeAutomationMutationSnapshot; i, j: Integer;
begin
  dry := xeAutomationReadBooleanArg(args, 'dryRun', specified); if not specified then dry := True;
  overwrite := xeAutomationReadBooleanArg(args, 'overwrite', specified);
  addMasters := xeAutomationReadBooleanArg(args, 'addRequiredMasters', specified); if not specified then addMasters := True;
  if not dry and not xeAutomationMutationPolicyConsentSatisfied(denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('selections.copy_into', 'records-mutation', denied));
  if args.Contains('deepCopy') or args.Contains('mode') then
    raise xeAutomationInvalidRequest('File/group selection copy always recursively copies owned records as overrides');
  if wbAllowMakePartial then raise xeAutomationMutationNotAllowed('Selection copy requires native partial-form creation disabled');
  target := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(args, 'targetFile'));
  xeAutomationRequireWritableTargetFile(target);
  selected := TList<IwbElement>.Create; nodes := TList<IwbElement>.Create;
  records := TList<IwbMainRecord>.Create; calls := TObjectList<TJsonObject>.Create(True);
  Result := TJsonObject.Create;
  try
    try
      ReadSelections(args, selected, nodes, records);
      OrderWithOwners(records, target);
      // Reuse full root-copy preflight. Distinct versions of one identity cannot
      // both become an override; require the caller to select one source version.
      for i := 0 to records.Count - 1 do begin
        if records[i]._File.LoadOrder >= target.LoadOrder then raise xeAutomationInvalidTarget('Copy target must load after every source');
        for j := 0 to i - 1 do if records[i].LoadOrderFormID = records[j].LoadOrderFormID then
          raise xeAutomationInvalidRequest('Selection contains multiple versions of one record identity');
        call := TJsonObject.Create; calls.Add(call);
        Identity(call.O['source'], records[i]);
        call.O['target'].S['file'] := target.FileName; call.O['target'].S['path'] := '';
        call.S['mode'] := 'override'; call.B['deepCopy'] := False;
        call.B['overwrite'] := overwrite; call.B['addRequiredMasters'] := addMasters;
        call.B['dryRun'] := True;
        response := xeAutomationExecuteCommand('records.copy_into', call);
        response.Free;
      end;
      snapshot := xeAutomationCaptureMutationSnapshot;
      Result.B['dryRun'] := dry; Result.B['complete'] := False;
      Result.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush; no file header clone';
      Result.S['emptyGroups'] := 'copy produces no records or empty-group clone; use create_group to create an empty top-level group';
      Result.I['plannedRecords'] := records.Count; Result.I['completedRecords'] := 0;
      Result.A['records'].Clear;
      for i := 0 to calls.Count - 1 do begin
        row := Result.A['records'].AddObject; row.O['source'].Assign(calls[i].O['source']);
        row.S['outcome'] := 'planned';
      end;
      if not dry then for i := 0 to calls.Count - 1 do begin
        calls[i].B['dryRun'] := False; row := Result.A['records'].O[i];
        row.S['outcome'] := 'attempted';
        try
          // Structural order is parent-before-child. Each payload copies once;
          // root deepCopy:false does not expand into its sibling child group.
          response := xeAutomationExecuteCommand('records.copy_into', calls[i]);
          try row.O['result'].Assign(response); finally response.Free; end;
          row.S['outcome'] := 'applied'; Result.I['completedRecords'] := i + 1;
        except on E: Exception do begin
          row.S['outcome'] := 'failed'; row.S['message'] := E.Message;
          if E is ExeAutomationError then begin
            Result.O['failure'].S['code'] := ExeAutomationError(E).Code;
            if Assigned(ExeAutomationError(E).Details) then Result.O['failure'].O['details'].Assign(ExeAutomationError(E).Details);
          end else Result.O['failure'].S['code'] := xeAutomationErrorInternalError;
          Result.O['failure'].S['message'] := E.Message; Result.O['failure'].I['index'] := i;
          Break;
        end; end;
      end;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], snapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      Result.B['pathInvalidated'] := Result.B['changed'];
      Result.B['requiresSave'] := Result.B['changed'];
      Result.B['complete'] := not Result.Contains('failure');
    except Result.Free; raise; end;
  finally calls.Free; records.Free; nodes.Free; selected.Free; end;
end;

function Remove(const args: TJsonObject): TJsonObject;
var selected, nodes: TList<IwbElement>; records: TList<IwbMainRecord>;
  dry, specified: Boolean; denied: string; i: Integer; row: TJsonObject;
  snapshot: TxeAutomationMutationSnapshot;
begin
  dry := xeAutomationReadBooleanArg(args, 'dryRun', specified); if not specified then dry := True;
  if not dry and not xeAutomationMutationPolicyConsentSatisfied(denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('selections.remove', 'records-mutation', denied));
  selected := TList<IwbElement>.Create; nodes := TList<IwbElement>.Create;
  records := TList<IwbMainRecord>.Create; Result := TJsonObject.Create;
  try
    try
      ReadSelections(args, selected, nodes, records);
      // File removal is never mapped to clearing plugins or deleting disk files.
      // All contained native gates are checked before recursive group.Remove.
      for i := 0 to selected.Count - 1 do if selected[i].ElementType = etFile then
        raise xeAutomationMutationNotAllowed('Native files cannot be removed; restart with a new plugin list to unload; no disk delete');
      for i := 0 to nodes.Count - 1 do begin
        xeAutomationRequireWritableTargetFile(nodes[i]._File);
        if not nodes[i].IsRemovable then raise xeAutomationMutationNotAllowed('Selection contains a non-removable native element');
      end;
      snapshot := xeAutomationCaptureMutationSnapshot;
      Result.B['dryRun'] := dry; Result.B['complete'] := False;
      Result.B['diskDeleted'] := False; Result.I['plannedRecords'] := records.Count;
      Result.S['persistence'] := 'recursive group removal in memory; explicit save/terminal flush; no unload or disk delete';
      Result.A['records'].Clear; Result.A['selections'].Clear;
      for i := 0 to records.Count - 1 do Identity(Result.A['records'].AddObject, records[i]);
      for i := 0 to selected.Count - 1 do begin
        row := Result.A['selections'].AddObject;
        row.S['file'] := selected[i]._File.FileName; row.A['groupPath'] := GroupPath(selected[i]);
        row.S['outcome'] := 'planned';
      end;
      if not dry then for i := 0 to selected.Count - 1 do begin
        row := Result.A['selections'].O[i]; row.S['outcome'] := 'attempted';
        try selected[i].Remove; row.S['outcome'] := 'applied';
        except on E: Exception do begin
          row.S['outcome'] := 'failed';
          if E is ExeAutomationError then begin
            Result.O['failure'].S['code'] := ExeAutomationError(E).Code;
            if Assigned(ExeAutomationError(E).Details) then Result.O['failure'].O['details'].Assign(ExeAutomationError(E).Details);
          end else Result.O['failure'].S['code'] := xeAutomationErrorInternalError;
          Result.O['failure'].S['message'] := E.Message;
          Result.O['failure'].I['index'] := i; Break;
        end; end;
      end;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], snapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      Result.B['pathInvalidated'] := Result.B['changed'];
      Result.B['requiresSave'] := Result.B['changed']; Result.B['complete'] := not Result.Contains('failure');
    except Result.Free; raise; end;
  finally records.Free; nodes.Free; selected.Free; end;
end;

function CreateGroup(const args: TJsonObject): TJsonObject;
var fileRef: IwbFile; group: IwbGroupRecord; signature: string; dry, specified: Boolean;
  denied: string; snapshot: TxeAutomationMutationSnapshot; definition: PwbMainRecordDef;
begin
  RequireMode;
  fileRef := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(args, 'file'));
  signature := UpperCase(xeAutomationRequireStringArg(args, 'signature'));
  if (Length(signature) <> 4) or (wbGroupOrder.IndexOf(signature) < 0) or
     (GroupToSkip.IndexOf(signature) >= 0) or (RecordToSkip.IndexOf(signature) >= 0) then
    raise xeAutomationInvalidTarget('Signature is not an enabled native top-level group');
  if not wbFindRecordDef(StrToSignature(signature), definition) or
     (dfInternalEditOnly in definition.DefFlags) then
    raise xeAutomationMutationNotAllowed('Group signature has no public native definition');
  dry := xeAutomationReadBooleanArg(args, 'dryRun', specified); if not specified then dry := True;
  if not dry and not xeAutomationMutationPolicyConsentSatisfied(denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('selections.create_group', 'files-mutation', denied));
  xeAutomationRequireWritableTargetFile(fileRef);
  snapshot := xeAutomationCaptureMutationSnapshot;
  group := fileRef.GroupBySignature[StrToSignature(signature)];
  Result := TJsonObject.Create;
  try
    Result.B['alreadyExists'] := Assigned(group); Result.B['dryRun'] := dry;
    if not dry and not Assigned(group) then
      if not Supports(fileRef.Add(signature, True), IwbGroupRecord, group) then
        raise xeAutomationInvalidTarget('Native top-level group creation returned no group');
    Result.S['file'] := fileRef.FileName; Result.S['signature'] := signature;
    if Assigned(group) then Result.A['groupPath'] := GroupPath(group);
    xeAutomationWriteMutationAudit(Result.O['mutationState'], snapshot);
    Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
    Result.S['persistence'] := 'in-memory group; native save may omit empty groups; add records before persisting';
  except
    on E: Exception do begin
      Result.Free;
      raise xeAutomationMutationFailure(E, xeAutomationErrorInvalidTarget,
        'selections.create_group', snapshot, []);
    end;
  end;
end;

procedure xeAutomationRegisterSelectionCommands;
begin
  xeAutomationRegisterCommand('selections.inspect', Inspect);
  xeAutomationRegisterCommand('selections.copy_into', CopyInto);
  xeAutomationRegisterCommand('selections.remove', Remove);
  xeAutomationRegisterCommand('selections.create_group', CreateGroup);
end;
end.
