{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsModGroups;
interface
procedure xeAutomationRegisterModGroupCommands;
implementation
uses Classes, SysUtils, System.Hash, JsonDataObjects, wbInterface, wbLoadOrder,
  wbHelpers, wbModGroups, xeMainForm, xeAutomationObjectModel,
  xeAutomationErrors, xeAutomationMutationPolicy, xeAutomationExternalIO,
  xeAutomationRecordQueries, xeAutomationRegistry;
type
  TIdentity = record Config, Name: string; end;
var
  Selected: TArray<TIdentity>;
  SelectionKnown, SelectedEnabled: Boolean;
  SelectionGeneration: UInt64;

function ConfigPath(const value: string): string;
var modules: TwbModuleInfos; i: Integer;
begin
  if (ExtractFileDrive(value) = '') or (Length(value) > 240) then
    raise xeAutomationInvalidRequest('configFile must be an absolute native-discoverable .modgroups path');
  xeAutomationExternalRoot(ExtractFilePath(value));
  Result := ExpandFileName(value);
  xeAutomationExternalRoot(ExtractFilePath(Result));
  if not SameText(ExtractFileExt(Result), '.modgroups') then raise xeAutomationInvalidRequest('Expected .modgroups extension');
  if SameText(Result, ExpandFileName(wbModGroupFileName)) then Exit;
  modules := wbModulesByLoadOrder;
  for i := Low(modules) to High(modules) do
    if SameText(Result, ExpandFileName(wbExpandFileName(ChangeFileExt(modules[i].miName, '.modgroups')))) then Exit;
  raise xeAutomationInvalidTarget('Config is not the global config or a loaded module native .modgroups sidecar');
end;

function ConfigHash(const path: string): string;
var stream: TFileStream;
begin
  if not FileExists(path) then Exit('absent');
  stream := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    if stream.Size > 1048576 then raise xeAutomationNewError('modgroup_capacity', 'Config exceeds 1 MiB');
    Result := THashSHA2.GetHashString(stream);
  finally stream.Free; end;
end;

function FindGroup(const config, name: string; const groups: TwbModGroupPtrs): PwbModGroup;
var i: Integer;
begin
  Result := nil;
  for i := Low(groups) to High(groups) do
    if SameText(groups[i].mgName, name) and Assigned(groups[i].mgModGroupsFile) and
       SameText(ExpandFileName(groups[i].mgModGroupsFile.mgfFileName), config) then Exit(groups[i]);
end;

procedure Describe(const row: TJsonObject; var group: TwbModGroup);
var messages: TwbMessagePtrs; i: Integer;
begin
  if Length(group.mgItems) > 64 then raise xeAutomationNewError('modgroup_capacity', 'Group exceeds 64 items');
  row.S['name'] := group.mgName;
  if Assigned(group.mgModGroupsFile) then row.S['configFile'] := ExpandFileName(group.mgModGroupsFile.mgfFileName);
  row.B['valid'] := group.IsValid;
  messages := group.GetValidationMessages;
  row.A['messages'].Clear;
  for i := Low(messages) to High(messages) do row.A['messages'].Add(Copy(messages[i].ToString, 1, 2048));
  if not row.B['valid'] and (Length(messages) = 0) then row.A['messages'].Add('Native required/forbidden/source/order predicates reject this group');
  row.A['items'].Clear;
  for i := Low(group.mgItems) to High(group.mgItems) do row.A['items'].Add(group.mgItems[i].ToString);
end;

function ListGroups(const args: TJsonObject): TJsonObject;
var groups: TwbModGroupPtrs; row: TJsonObject; i: Integer; config: string;
begin
  groups := wbModGroupsByName(False);
  if Length(groups) > 128 then raise xeAutomationNewError('modgroup_capacity', 'Loaded group inventory exceeds 128');
  config := '';
  if args.Contains('configFile') then config := ConfigPath(xeAutomationRequireStringArg(args, 'configFile'));
  Result := TJsonObject.Create;
  try
    Result.A['groups'].Clear;
    if config <> '' then Result.S['fileHash'] := ConfigHash(config);
    for i := Low(groups) to High(groups) do begin
      if (config <> '') and not SameText(ExpandFileName(groups[i].mgModGroupsFile.mgfFileName), config) then Continue;
      row := Result.A['groups'].AddObject;
      Describe(row, groups[i]^);
      row.S['fileHash'] := ConfigHash(row.S['configFile']);
    end;
    Result.B['selectionKnown'] := SelectionKnown and (SelectionGeneration = wbModGroupsActivationGeneration) and
      Assigned(frmMain) and (frmMain.ModGroupsEnabled = SelectedEnabled);
    Result.S['selectionRevision'] := UIntToStr(wbModGroupsActivationGeneration);
    Result.B['enabled'] := Assigned(frmMain) and frmMain.ModGroupsEnabled;
    Result.S['persistence'] := 'read native config validation; active selection is session-only';
  except Result.Free; raise; end;
end;

function ReadSelection(const args: TJsonObject): TArray<TIdentity>;
var values: TJsonArray; i, j: Integer;
begin
  if not args.Contains('groups') or (args.Types['groups'] <> jdtArray) then raise xeAutomationInvalidRequest('groups must be an array of configFile/name identities');
  values := args.A['groups'];
  if values.Count > 32 then raise xeAutomationInvalidRequest('Select at most 32 groups; [] disables relationships');
  SetLength(Result, values.Count);
  for i := 0 to values.Count - 1 do begin
    if values.Types[i] <> jdtObject then raise xeAutomationInvalidRequest('Group identity must be an object');
    Result[i].Config := ConfigPath(xeAutomationRequireStringArg(values.O[i], 'configFile'));
    Result[i].Name := xeAutomationRequireStringArg(values.O[i], 'name');
    for j := 0 to i - 1 do
      if SameText(Result[i].Config, Result[j].Config) and SameText(Result[i].Name, Result[j].Name) then raise xeAutomationInvalidRequest('Duplicate group identity');
  end;
end;

procedure ApplySelection(const identities: TArray<TIdentity>; enabled, allowMissing: Boolean; const resultObject: TJsonObject);
var all, chosen: TwbModGroupPtrs; p: PwbModGroup; i: Integer; exist: Boolean; resolved: TArray<TIdentity>;
begin
  if not Assigned(frmMain) then raise xeAutomationInvalidTarget('ModGroup activation requires a loaded main form');
  all := wbModGroupsByName(False);
  chosen := nil;
  resultObject.A['droppedGroups'].Clear;
  // Resolve fresh native pointers and validate all selections before Activate
  // clears/rebuilds module source/target edges.
  for i := Low(identities) to High(identities) do begin
    p := FindGroup(identities[i].Config, identities[i].Name, all);
    if not Assigned(p) or not p.IsValid then begin
      if not allowMissing then raise xeAutomationInvalidTarget('Selected group is missing or natively invalid: ' + identities[i].Name);
      resultObject.A['droppedGroups'].Add(identities[i].Config + ':' + identities[i].Name);
      Continue;
    end;
    SetLength(chosen, Length(chosen) + 1); chosen[High(chosen)] := p;
    SetLength(resolved, Length(resolved) + 1);
    resolved[High(resolved)].Config := identities[i].Config;
    resolved[High(resolved)].Name := identities[i].Name;
  end;
  SelectionKnown := False;
  xeAutomationInvalidateRecordQueries;
  // Conflict reset can pump VCL messages. Own the short native transition and
  // snapshot identities before it, so GUI reload cannot invalidate pointers.
  wbLockProcessMessages;
  try
    exist := chosen.Activate;
    frmMain.AutomationSetModGroupsState(exist, enabled);
  finally wbUnLockProcessMessages; end;
  xeAutomationInvalidateRecordQueries;
  Selected := resolved;
  SelectionKnown := True; SelectedEnabled := frmMain.ModGroupsEnabled;
  SelectionGeneration := wbModGroupsActivationGeneration;
  resultObject.B['enabled'] := frmMain.ModGroupsEnabled;
  resultObject.B['relationshipsExist'] := exist;
  resultObject.S['selectionRevision'] := UIntToStr(SelectionGeneration);
  resultObject.B['complete'] := True;
end;

function Activate(const args: TJsonObject): TJsonObject;
var ids: TArray<TIdentity>; enabled, specified: Boolean; denied: string; beforeGeneration: UInt64;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(denied) then Exit(xeAutomationErrorsBuildConsentRequired('modgroups.activate', 'session-state', denied));
  ids := ReadSelection(args);
  enabled := xeAutomationReadBooleanArg(args, 'enabled', specified);
  if not specified then enabled := True;
  Result := TJsonObject.Create;
  beforeGeneration := wbModGroupsActivationGeneration;
  try
    Result.B['complete'] := False;
    try ApplySelection(ids, enabled, False, Result);
    except
      on E: Exception do begin
        if wbModGroupsActivationGeneration <> beforeGeneration then begin
          Result.O['failure'].S['phase'] := 'activation';
          Result.O['failure'].S['message'] := E.Message;
          Result.O['failure'].B['partialKnown'] := False;
        end else raise;
      end;
    end;
    Result.S['persistence'] := 'session selection/conflict state; plugin data unchanged; no config selection saved';
  except Result.Free; raise; end;
end;

procedure RequireKnownSelection;
begin
  if not SelectionKnown or (SelectionGeneration <> wbModGroupsActivationGeneration) or
     not Assigned(frmMain) or (frmMain.ModGroupsEnabled <> SelectedEnabled) then
    raise xeAutomationStateConflict('Call modgroups.activate with explicit identities before config reload/write; GUI selection cannot be inferred safely');
end;

function Reload(const args: TJsonObject): TJsonObject;
var denied: string; ids: TArray<TIdentity>;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(denied) then Exit(xeAutomationErrorsBuildConsentRequired('modgroups.reload', 'session-state', denied));
  RequireKnownSelection;
  ids := Copy(Selected);
  Result := TJsonObject.Create;
  try
    xeAutomationInvalidateRecordQueries;
    wbReloadModGroups;
    ApplySelection(ids, SelectedEnabled, True, Result);
    Result.S['persistence'] := 'reload external config and restore still-valid session identities';
  except SelectionKnown := False; Result.Free; raise; end;
end;

procedure CheckName(const name: string);
var i: Integer;
begin
  if (name = '') or (Length(name) > 128) then raise xeAutomationInvalidRequest('Group name must contain 1..128 characters');
  for i := 1 to Length(name) do
    if (Ord(name[i]) < 32) or CharInSet(name[i], ['[', ']']) then raise xeAutomationInvalidRequest('Invalid INI section name');
end;

procedure ReadLines(const args: TJsonObject; const lines: TStringList);
var rows: TJsonArray; s, tail: string; i, j, posColon: Integer; crc: TwbCRC32; parts: TArray<string>;
begin
  if not args.Contains('items') or (args.Types['items'] <> jdtArray) then raise xeAutomationInvalidRequest('items must be native ModGroup lines');
  rows := args.A['items'];
  if (rows.Count < 2) or (rows.Count > 64) then raise xeAutomationInvalidRequest('Group needs 2..64 item lines');
  for i := 0 to rows.Count - 1 do begin
    if rows.Types[i] <> jdtString then raise xeAutomationInvalidRequest('Item lines must be strings');
    s := Trim(rows.S[i]);
    if (s = '') or (Length(s) > 512) then raise xeAutomationInvalidRequest('Empty/oversized item line');
    for j := 1 to Length(s) do
      if (Ord(s[j]) < 32) or CharInSet(s[j], ['[', ']', ';', '=']) then raise xeAutomationInvalidRequest('INI injection/comment item syntax is refused');
    posColon := Pos(':', s);
    tail := s;
    if posColon > 0 then begin
      tail := Copy(s, posColon + 1, MaxInt);
      parts := tail.Split([',']);
      if Length(parts) > 16 then raise xeAutomationInvalidRequest('Item permits at most 16 historical CRCs');
      for tail in parts do
        if not crc.AssignFromString(Trim(tail)) or not crc.IsValid then raise xeAutomationInvalidRequest('CRC must be eight hex digits excluding native sentinel values');
      tail := Copy(s, 1, posColon - 1);
    end;
    j := 1;
    while (j <= Length(tail)) and CharInSet(tail[j], [' ', '+', '-', '!', '@', '#', '{', '}']) do Inc(j);
    tail := Trim(Copy(tail, j, MaxInt));
    if (tail = '') or (ExtractFileName(tail) <> tail) or not
       (SameText(ExtractFileExt(tail), '.esm') or SameText(ExtractFileExt(tail), '.esp') or SameText(ExtractFileExt(tail), '.esl')) then
      raise xeAutomationInvalidRequest('Item must name a plugin basename after native flag prefixes');
    lines.Add(s);
  end;
end;

procedure ReplaceSection(const lines: TStringList; const oldName: string; const replacement: TArray<string>);
var i, j, first, last: Integer; s: string;
begin
  first := -1; last := lines.Count;
  for i := 0 to lines.Count - 1 do begin
    s := Trim(lines[i]);
    if (Length(s) >= 2) and (s[1] = '[') and (s[Length(s)] = ']') then begin
      if first >= 0 then begin last := i; Break; end;
      if SameText(Copy(s, 2, Length(s) - 2), oldName) then first := i;
    end;
  end;
  if first >= 0 then begin
    for j := last - 1 downto first do lines.Delete(j);
  end else first := lines.Count;
  for i := High(replacement) downto Low(replacement) do lines.Insert(first, replacement[i]);
end;

function ReadSection(const lines: TStringList; const name: string; const items: TStringList): Boolean;
var i, count: Integer; s: string; inSection: Boolean; names: TStringList;
begin
  Result := False; inSection := False; count := 0;
  names := TStringList.Create;
  try
    for i := 0 to lines.Count - 1 do begin
      s := Trim(lines[i]);
      if (Length(s) > 1) and (s[1] = '[') and (s[Length(s)] = ']') then begin
        s := Copy(s, 2, Length(s) - 2);
        if names.IndexOf(s) >= 0 then raise xeAutomationInvalidTarget('Duplicate config section names are ambiguous');
        names.Add(s); Inc(count);
        if count > 128 then raise xeAutomationNewError('modgroup_capacity', 'Config exceeds 128 sections');
        inSection := SameText(s, name); Result := Result or inSection;
      end else if inSection and (s <> '') and not s.StartsWith(';') then items.Add(s);
    end;
  finally names.Free; end;
end;

function MutateConfig(const args: TJsonObject; refreshCRC: Boolean): TJsonObject;
var
  path, name, newName, op, expected, denied: string;
  dry, specified, allowInvalid, add, update, exists: Boolean;
  candidate: TwbModGroup;
  items, fileLines, selectedFiles: TStringList; stream: TMemoryStream;
  ids: TArray<TIdentity>; values: TJsonArray; crc: TwbCRC32;
  i, j, changed: Integer;
begin
  path := ConfigPath(xeAutomationRequireStringArg(args, 'configFile'));
  name := xeAutomationRequireStringArg(args, 'name'); CheckName(name);
  expected := xeAutomationRequireStringArg(args, 'expectedFileHash');
  if ConfigHash(path) <> expected then raise xeAutomationStateConflict('Config hash differs from expectedFileHash');
  dry := xeAutomationReadBooleanArg(args, 'dryRun', specified); if not specified then dry := True;
  if not dry and not xeAutomationMutationPolicyConsentSatisfied(denied) then Exit(xeAutomationErrorsBuildConsentRequired('modgroups.config', 'external-config-write', denied));
  items := TStringList.Create; fileLines := TStringList.Create; selectedFiles := TStringList.Create; stream := TMemoryStream.Create;
  Result := TJsonObject.Create;
  try
    try
      changed := 0; newName := name;
      if FileExists(path) then fileLines.LoadFromFile(path);
      exists := ReadSection(fileLines, name, items);
      if refreshCRC then begin
        op := 'update';
        if not exists then raise xeAutomationInvalidTarget('ModGroup not found');
        // Reparse serialization into independent arrays. Record assignment
        // would alias live item/CRC arrays and mutate them during dry run.
        candidate.LoadCandidate(items); candidate.mgName := name;
        if (Length(candidate.mgItems) <> items.Count) or (items.Count > 64) then raise xeAutomationInvalidTarget('Existing group contains malformed/oversized item lines');
        if not args.Contains('files') or (args.Types['files'] <> jdtArray) then raise xeAutomationInvalidRequest('CRC refresh requires explicit files array');
        values := args.A['files'];
        if (values.Count < 1) or (values.Count > 64) then raise xeAutomationInvalidRequest('CRC files needs 1..64 names');
        for i := 0 to values.Count - 1 do begin
          if values.Types[i] <> jdtString then raise xeAutomationInvalidRequest('CRC filenames must be strings');
          selectedFiles.Add(Trim(values.S[i]));
          exists := False;
          for j := Low(candidate.mgItems) to High(candidate.mgItems) do
            exists := exists or SameText(candidate.mgItems[j].mgiFileName, selectedFiles[i]);
          if not exists then raise xeAutomationInvalidTarget('CRC filename is not an item in this group');
        end;
        add := xeAutomationReadBooleanArg(args, 'addMissing', specified); if not specified then add := True;
        update := xeAutomationReadBooleanArg(args, 'appendCurrent', specified); if not specified then update := True;
        for i := Low(candidate.mgItems) to High(candidate.mgItems) do with candidate.mgItems[i] do begin
          if selectedFiles.IndexOf(mgiFileName) < 0 then Continue;
          if mgifForbidden in mgiFlags then Continue;
          if not Assigned(mgiModule) or not Assigned(mgiModule.miFile) then raise xeAutomationInvalidTarget('CRC item needs a loaded plugin');
          if mgiModule._File.Modified then raise xeAutomationStateConflict('CRC refresh requires saved/fresh loaded plugins');
          if not mgiModule.GetCRC32(crc) or not crc.IsValid then raise xeAutomationInvalidTarget('Native module CRC unavailable');
          if (Length(mgiCRC32s) = 0) and not add then Continue;
          if (Length(mgiCRC32s) > 0) and not update then Continue;
          if mgiCRC32s.Contains(crc) then Continue;
          if Length(mgiCRC32s) >= 16 then raise xeAutomationNewError('modgroup_capacity', 'CRC history exceeds 16 entries');
          mgiCRC32s.Add(crc); Inc(changed);
        end;
      end else begin
        op := xeAutomationRequireStringArg(args, 'operation');
        if (op <> 'create') and (op <> 'update') and (op <> 'delete') then raise xeAutomationInvalidRequest('operation must be create/update/delete');
        if (op = 'create') and exists then raise xeAutomationStateConflict('ModGroup already exists');
        if (op <> 'create') and not exists then raise xeAutomationInvalidTarget('ModGroup not found');
        if op <> 'delete' then begin
          if args.Contains('newName') then newName := xeAutomationRequireStringArg(args, 'newName');
          CheckName(newName);
          items.Clear;
          if not SameText(newName, name) and ReadSection(fileLines, newName, items) then raise xeAutomationStateConflict('Renamed group already exists');
          items.Clear;
          ReadLines(args, items);
          candidate.LoadCandidate(items); candidate.mgName := newName;
          if Length(candidate.mgItems) <> items.Count then raise xeAutomationInvalidRequest('Native parser did not admit every item');
        end;
      end;
      Result.S['configFile'] := path; Result.S['name'] := name; Result.S['operation'] := op;
      Result.B['dryRun'] := dry; Result.B['written'] := False;
      Result.I['changedCRCItems'] := changed;
      if op <> 'delete' then begin
        Describe(Result.O['candidate'], candidate);
        allowInvalid := xeAutomationReadBooleanArg(args, 'allowInvalid', specified); if not specified then allowInvalid := False;
        if not Result.O['candidate'].B['valid'] and not allowInvalid then
          raise xeAutomationNewError(xeAutomationErrorInvalidTarget, 'Candidate fails native ModGroup validation; inspect details or explicitly allowInvalid', Result.O['candidate']);
      end;
      if op = 'delete' then ReplaceSection(fileLines, name, nil)
      else ReplaceSection(fileLines, name, candidate.ToStrings);
      items.Clear;
      exists := ReadSection(fileLines, newName, items);
      if (op = 'create') and (Length(wbModGroupsByName(False)) >= 128) then
        raise xeAutomationNewError('modgroup_capacity', 'New group would exceed 128 loaded groups');
      fileLines.SaveToStream(stream, TEncoding.UTF8);
      if stream.Size > 1048576 then raise xeAutomationNewError('modgroup_capacity', 'Updated config exceeds 1 MiB');
      Result.S['persistence'] := 'immediate external config, per-file atomic; selection session-only; plugins unchanged';
      if dry then Exit;
      RequireKnownSelection;
      ids := Copy(Selected);
      if op = 'update' then
        for j := Low(ids) to High(ids) do
          if SameText(ids[j].Config, path) and SameText(ids[j].Name, name) then ids[j].Name := newName;
      if ConfigHash(path) <> expected then raise xeAutomationStateConflict('Config changed during planning');
      xeAutomationAtomicWrite(path, stream, expected <> 'absent');
      Result.B['written'] := True;
      try
        Result.S['fileHash'] := ConfigHash(path);
        xeAutomationInvalidateRecordQueries;
        wbReloadModGroups;
        ApplySelection(ids, SelectedEnabled, True, Result);
      except
        on E: Exception do begin
          SelectionKnown := False;
          Result.O['failure'].S['phase'] := 'reload-after-persist';
          Result.O['failure'].S['message'] := E.Message;
          Result.O['failure'].B['partial'] := True;
        end;
      end;
    except Result.Free; raise; end;
  finally stream.Free; selectedFiles.Free; fileLines.Free; items.Free; end;
end;

function WriteGroup(const args: TJsonObject): TJsonObject;
begin Result := MutateConfig(args, False); end;
function RefreshCRC(const args: TJsonObject): TJsonObject;
begin Result := MutateConfig(args, True); end;

procedure xeAutomationRegisterModGroupCommands;
begin
  xeAutomationRegisterCommand('modgroups.list', ListGroups);
  xeAutomationRegisterCommand('modgroups.activate', Activate);
  xeAutomationRegisterCommand('modgroups.reload', Reload);
  xeAutomationRegisterCommand('modgroups.write', WriteGroup);
  xeAutomationRegisterCommand('modgroups.refresh_crc', RefreshCRC);
end;
end.
