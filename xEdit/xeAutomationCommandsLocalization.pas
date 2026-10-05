{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsLocalization;
interface
procedure xeAutomationRegisterLocalizationCommands;
implementation
uses Classes, SysUtils, System.Generics.Collections, JsonDataObjects,
  wbInterface, wbLoadOrder, wbLocalization, xeAutomationDataLookup,
  xeAutomationObjectModel, xeAutomationErrors, xeAutomationMutationPolicy,
  xeAutomationMutationAudit, xeAutomationLocalizationState,
  xeAutomationExternalIO, xeAutomationRecordQueries, xeAutomationRegistry;

procedure RequireGame;
begin
  if not (wbIsSkyrim or wbIsFallout4 or wbIsFallout76 or wbIsStarfield) then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
      'Localization requires Skyrim, Fallout 4, Fallout 76 or Starfield definitions');
end;

function ReadType(const AArgs: TJsonObject): TwbLStringType;
var s: string;
begin
  s := xeAutomationRequireStringArg(AArgs, 'type');
  if SameText(s, 'STRINGS') then Exit(lsString);
  if SameText(s, 'DLSTRINGS') then Exit(lsDLString);
  if SameText(s, 'ILSTRINGS') then Exit(lsILString);
  raise xeAutomationInvalidRequest('type must be STRINGS, DLSTRINGS or ILSTRINGS');
end;

function FindTable(const AFile: IwbFile; AType: TwbLStringType): TwbLocalizationFile;
var i: Integer; s: string;
begin
  Result := nil;
  s := ExtractFileName(wbLocalizationHandler.GetLocalizationFileNameByType(AFile.FileName, AType));
  for i := 0 to wbLocalizationHandler.Count - 1 do
    if SameText(wbLocalizationHandler[i].Name, s) then Exit(wbLocalizationHandler[i]);
end;

function RequireTable(const AArgs: TJsonObject; out AFile: IwbFile): TwbLocalizationFile;
begin
  RequireGame;
  AFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  wbLocalizationHandler.LoadForFile(AFile.FileName);
  Result := FindTable(AFile, ReadType(AArgs));
  if not Assigned(Result) then raise xeAutomationInvalidTarget('Requested language table resource is missing');
end;

procedure DescribeTable(const AResult: TJsonObject; const ATable: TwbLocalizationFile);
begin
  AResult.S['name'] := ATable.Name;
  AResult.S['encoding'] := ATable.PrimaryEncodingName;
  AResult.I['count'] := ATable.Count;
  AResult.B['modified'] := ATable.Modified;
  AResult.S['language'] := wbLanguage;
end;

function Tables(const AArgs: TJsonObject): TJsonObject;
var f: IwbFile; t: TwbLocalizationFile; k: TwbLStringType; row: TJsonObject;
begin
  RequireGame;
  f := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  wbLocalizationHandler.LoadForFile(f.FileName);
  Result := TJsonObject.Create;
  try
    Result.S['file'] := f.FileName;
    Result.S['language'] := wbLanguage;
    Result.B['localized'] := f.IsLocalized;
    Result.A['tables'].Clear;
    for k := Low(TwbLStringType) to High(TwbLStringType) do begin
      row := Result.A['tables'].AddObject;
      row.S['type'] := Copy(wbLocalizationExtension[k], 2, MaxInt);
      t := FindTable(f, k);
      row.B['present'] := Assigned(t);
      if Assigned(t) then DescribeTable(row, t);
    end;
  except Result.Free; raise; end;
end;

function GetString(const AArgs: TJsonObject): TJsonObject;
var f: IwbFile; t: TwbLocalizationFile; id: Cardinal; value: string;
begin
  t := RequireTable(AArgs, f);
  id := xeAutomationParseFormIdHex(xeAutomationRequireStringArg(AArgs, 'id'));
  if not t.Find(id, value) then raise xeAutomationInvalidTarget('String ID does not exist in the selected table');
  Result := TJsonObject.Create;
  DescribeTable(Result, t);
  Result.S['id'] := IntToHex(id, 8);
  Result.S['value'] := value;
end;

function SetString(const AArgs: TJsonObject): TJsonObject;
var f: IwbFile; t: TwbLocalizationFile; id: Cardinal; value, old, denied: string;
begin
  t := RequireTable(AArgs, f);
  if not xeAutomationMutationPolicyConsentSatisfied(denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('localization.set', 'string-table-mutation', denied));
  xeAutomationRequireWritableTargetFile(f);
  id := xeAutomationParseFormIdHex(xeAutomationRequireStringArg(AArgs, 'id'));
  if (id = 0) or not t.Find(id, old) then raise xeAutomationInvalidTarget('Edit requires an existing nonzero string ID');
  if xeAutomationRequireRawStringArg(AArgs, 'expectedValue') <> old then
    raise xeAutomationStateConflict('String value differs from expectedValue');
  value := xeAutomationRequireRawStringArg(AArgs, 'value');
  t.RequireLossless(value);
  t[id] := value;
  // Shared IDs change every referring field without notifying a plugin setter.
  // Cache generations and cursors therefore need explicit invalidation.
  if old <> value then begin
    Inc(wbLocalizationHandler.Generation);
    xeAutomationInvalidateRecordQueries;
  end;
  Result := TJsonObject.Create;
  DescribeTable(Result, t);
  Result.B['changed'] := old <> value;
  Result.S['value'] := t[id];
  Result.S['persistence'] := 'table-memory; localization.save required; shared-ID affects all referring fields';
end;

function Language(const AArgs: TJsonObject): TJsonObject;
var s, denied: string; modules: TwbModuleInfos; f: IwbFile; i: Integer;
begin
  RequireGame;
  if AArgs.Contains('language') then begin
    s := LowerCase(xeAutomationRequireStringArg(AArgs, 'language'));
    if (Length(s) > 32) then raise xeAutomationInvalidRequest('Language exceeds 32 characters');
    for i := 1 to Length(s) do
      if not CharInSet(s[i], ['a'..'z', '0'..'9', '_', '-']) then
        raise xeAutomationInvalidRequest('Language must be a resource language name');
    if not SameText(s, wbLanguage) then begin
      if not xeAutomationMutationPolicyConsentSatisfied(denied) then
        Exit(xeAutomationErrorsBuildConsentRequired('localization.language', 'session-state', denied));
      // Clear destroys all cached tables. Refuse unsaved plugins too: their
      // localized ID edits may depend on the old language's resources.
      if xeAutomationLocalizationHasDirtyTables then raise xeAutomationStateConflict('Save modified string tables before changing language');
      modules := wbModulesByLoadOrder;
      for i := Low(modules) to High(modules) do begin
        f := xeAutomationTryPluginFileFromModule(modules[i]);
        if Assigned(f) and f.Modified then raise xeAutomationStateConflict('Save and restart modified plugins before changing language');
      end;
      xeAutomationInvalidateRecordQueries;
      wbLanguage := s;
      wbLocalizationHandler.Clear;
      try
        for i := Low(modules) to High(modules) do begin
          f := xeAutomationTryPluginFileFromModule(modules[i]);
          if Assigned(f) and f.IsLocalized then wbLocalizationHandler.LoadForFile(f.FileName);
        end;
      except
        // A failed reload leaves a partial resource cache; do not keep editing.
        xeAutomationLocalizationRestartRequired := True;
        raise;
      end;
    end;
  end;
  Result := TJsonObject.Create;
  Result.S['language'] := wbLanguage;
  Result.S['persistence'] := 'session-only; resource names determine availability; unresolved fields fail native checks';
  Result.I['cacheGeneration'] := wbLocalizationHandler.Generation;
end;

function Convert(const AArgs: TJsonObject): TJsonObject;
var
  f: IwbFile; elements: TList<IwbElement>; texts: TList<string>;
  probes: array[TwbLStringType] of TwbLocalizationFile;
  t: TwbLocalizationFile; e: IwbElement; def: IwbBaseStringDef; fixedDef: IwbStringDef; data: IwbDataContainer;
  encoding: TEncoding; mode, s, denied: string; k: TwbLStringType;
  dry, specified, localize, oldTranslate, oldReuse, reuse: Boolean;
  visits, bytes, i: Integer; id: Cardinal; snapshot: TxeAutomationMutationSnapshot;

  procedure Gather(const aElement: IwbElement; depth: Integer);
  var c: IwbContainerElementRef; j: Integer;
  begin
    Inc(visits);
    if (visits > 100000) or (depth > 64) then raise xeAutomationNewError('localization_capacity', 'Conversion traversal exceeds its budget');
    if Assigned(aElement.ValueDef) and (aElement.ValueDef.DefType = dtLString) then begin
      if elements.Count >= 1000 then raise xeAutomationNewError('localization_capacity', 'Conversion allows at most 1000 localized fields');
      xeAutomationRequireWritableElementTarget(aElement);
      if not localize and (aElement.Check <> '') then raise xeAutomationInvalidTarget('Unresolved localized ID: ' + aElement.FullPath);
      s := aElement.EditValue;
      if (Length(s) > 1048576) or (Pos(#0, s) > 0) or s.StartsWith(sStringID) then
        raise xeAutomationInvalidTarget('Unrepresentable/ambiguous conversion text: ' + aElement.FullPath);
      Inc(bytes, TEncoding.UTF8.GetByteCount(s));
      if bytes > 4194304 then raise xeAutomationNewError('localization_capacity', 'Conversion text exceeds 4 MiB');
      if localize then begin
        k := wbLocalizationHandler.LocalizedValueDecider(aElement);
        probes[k].RequireLossless(s);
      end else begin
        if not Supports(aElement.ValueDef, IwbBaseStringDef, def) then raise xeAutomationInvalidTarget('Missing inline encoding definition');
        // Match the native setter's encoding decision on the original ID bytes.
        if not Supports(aElement, IwbDataContainer, data) then raise xeAutomationInvalidTarget('Missing inline storage');
        encoding := def.EffectiveEncoding(data.DataBasePtr, data.DataEndPtr, aElement);
        if encoding.GetString(encoding.GetBytes(s)) <> s then raise xeAutomationInvalidTarget('Delocalized text cannot roundtrip through inline encoding');
        if Supports(aElement.ValueDef, IwbStringDef, fixedDef) and (fixedDef.StringSize > 0) then
          if encoding.GetByteCount(s) > fixedDef.StringSize then raise xeAutomationInvalidTarget('Delocalized value exceeds fixed string size');
        begin
          // With NoTranslate the setter compares against eight-digit raw IDs.
          // Refuse the rare equality case rather than silently skip conversion.
          oldTranslate := wbLocalizationHandler.NoTranslate;
          wbLocalizationHandler.NoTranslate := True;
          try
            if aElement.EditValue = s then raise xeAutomationInvalidTarget('Text equals raw ID; native conversion setter would skip it');
          finally wbLocalizationHandler.NoTranslate := oldTranslate; end;
        end;
      end;
      elements.Add(aElement);
      texts.Add(s);
    end;
    if Supports(aElement, IwbContainerElementRef, c) then
      for j := c.ElementCount - 1 downto 0 do Gather(c.Elements[j], depth + 1);
  end;
begin
  RequireGame;
  f := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  xeAutomationRequireWritableTargetFile(f);
  if f.LoadOrder = 0 then raise xeAutomationInvalidTarget('Conversion refuses load-order zero');
  mode := xeAutomationRequireStringArg(AArgs, 'mode');
  if (mode <> 'localize') and (mode <> 'delocalize') then raise xeAutomationInvalidRequest('mode must be localize or delocalize');
  localize := mode = 'localize';
  dry := xeAutomationReadBooleanArg(AArgs, 'dryRun', specified);
  if not specified then dry := True;
  reuse := xeAutomationReadBooleanArg(AArgs, 'reuseDuplicates', specified);
  if not specified then reuse := False;
  if not dry and not xeAutomationMutationPolicyConsentSatisfied(denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('localization.convert', 'plugin-and-table-mutation', denied));
  if wbLocalizationHandler.NoTranslate then raise xeAutomationStateConflict('Conversion requires resolved native string reads');
  Result := TJsonObject.Create;
  elements := TList<IwbElement>.Create;
  texts := TList<string>.Create;
  for k := Low(TwbLStringType) to High(TwbLStringType) do probes[k] := nil;
  try
    try
      Result.S['file'] := f.FileName;
      Result.S['mode'] := mode;
      Result.B['dryRun'] := dry;
      Result.B['changed'] := False;
      Result.B['complete'] := True;
      Result.S['persistence'] := 'localization.save tables, session.save plugin, terminal session.flush and restart; partial failure has no rollback';
      if f.IsLocalized = localize then Exit;
      wbLocalizationHandler.LoadForFile(f.FileName);
      for k := Low(TwbLStringType) to High(TwbLStringType) do begin
        probes[k] := TwbLocalizationFile.Create(wbDataPath + wbLocalizationHandler.GetLocalizationFileNameByType(f.FileName, k), nil);
        t := FindTable(f, k);
        if Assigned(t) then begin
          if t.NextID > High(Cardinal) - 1001 then raise xeAutomationNewError('localization_capacity', 'String ID space exhausted');
          for i := 0 to t.Count - 1 do t.RequireLossless(t.Items[i]);
        end;
      end;
      visits := 0; bytes := 0;
      Gather(f, 0);
      if localize then
        for k := Low(TwbLStringType) to High(TwbLStringType) do begin
          t := FindTable(f, k);
          if Assigned(t) and (t.Count + elements.Count > 1000000) then
            raise xeAutomationNewError('localization_capacity', 'Converted table may exceed one million entries');
        end;
      Result.I['fieldCount'] := elements.Count;
      if dry then Exit;
      snapshot := xeAutomationCaptureMutationSnapshot;
      oldTranslate := wbLocalizationHandler.NoTranslate;
      oldReuse := wbLocalizationHandler.ReuseDup;
      // A first attempted representation change may fail halfway. The native GUI
      // closes after conversion; enforce the same no-further-edit boundary here.
      xeAutomationLocalizationRestartRequired := True;
      xeAutomationInvalidateRecordQueries;
      wbLocalizationHandler.ReuseDup := reuse;
      Result.I['completedFields'] := 0;
      try
        try
          for i := 0 to elements.Count - 1 do begin
            e := elements[i];
            if localize then begin
              id := wbLocalizationHandler.AddValue(texts[i], e);
              e.EditValue := sStringID + IntToHex(id, 8);
            end else begin
              wbLocalizationHandler.NoTranslate := True;
              e.EditValue := texts[i];
              wbLocalizationHandler.NoTranslate := oldTranslate;
            end;
            Result.I['completedFields'] := i + 1;
          end;
          f.IsLocalized := localize;
          Result.B['changed'] := True;
        except
          on E: Exception do begin
            Result.B['complete'] := False;
            Result.O['failure'].S['code'] := 'localization_conversion_failed';
            Result.O['failure'].S['message'] := E.Message;
            Result.O['failure'].B['partialKnown'] := False;
            Result.O['failure'].B['rollbackComplete'] := False;
          end;
        end;
      finally
        wbLocalizationHandler.NoTranslate := oldTranslate;
        wbLocalizationHandler.ReuseDup := oldReuse;
        Inc(wbLocalizationHandler.Generation);
      end;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], snapshot);
      Result.B['restartRequired'] := True;
      xeAutomationWriteLocalizationDirtyState(Result);
    except Result.Free; raise; end;
  finally
    for k := Low(TwbLStringType) to High(TwbLStringType) do probes[k].Free;
    texts.Free; elements.Free;
  end;
end;

function OutputTables(const AArgs: TJsonObject; textExport: Boolean): TJsonObject;
var
  f: IwbFile; k: TwbLStringType; t: TwbLocalizationFile;
  root, path, denied: string; overwrite, specified: Boolean;
  streams: array[TwbLStringType] of TMemoryStream;
  tables: array[TwbLStringType] of TwbLocalizationFile;
  lines: TStringList; b: TBytes; i: Integer; row: TJsonObject;
begin
  RequireGame;
  if not xeAutomationMutationPolicyConsentSatisfied(denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('localization.output', 'external-file-write', denied));
  f := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  if not textExport then xeAutomationRequireWritableTargetFile(f);
  root := xeAutomationExternalRoot(xeAutomationRequireStringArg(AArgs, 'outputDirectory'));
  overwrite := xeAutomationReadBooleanArg(AArgs, 'overwrite', specified);
  if not specified then overwrite := False;
  wbLocalizationHandler.LoadForFile(f.FileName);
  for k := Low(TwbLStringType) to High(TwbLStringType) do begin streams[k] := nil; tables[k] := nil; end;
  Result := TJsonObject.Create;
  try
    try
      Result.A['outputs'].Clear;
      Result.B['complete'] := False;
      Result.S['persistence'] := 'immediate external files; outputDirectory must be projected into runtime Strings for reload; plugin save remains separate';
      // Serialize and preflight every table before exposing the first output.
      // Atomicity is per file; a later rename failure retains earlier outputs.
      for k := Low(TwbLStringType) to High(TwbLStringType) do begin
        t := FindTable(f, k);
        if not Assigned(t) then Continue;
        tables[k] := t;
        streams[k] := TMemoryStream.Create;
        path := root + t.Name;
        if textExport then begin
          path := path + '.txt';
          lines := TStringList.Create;
          try
            for i := 0 to t.Count - 1 do begin
              lines.Add('[' + IntToHex(t.IndexToID(i), 8) + ']');
              lines.Add(t.Items[i]);
            end;
            b := TEncoding.UTF8.GetBytes(lines.Text);
            if Length(b) > 67108864 then raise xeAutomationNewError('localization_capacity', 'Text output exceeds 64 MiB');
            if Length(b) > 0 then streams[k].WriteBuffer(b[0], Length(b));
          finally lines.Free; end;
        end else t.WriteToStream(streams[k]);
        if FileExists(path) and not overwrite then raise xeAutomationStateConflict('Output exists: ' + path);
      end;
      for k := Low(TwbLStringType) to High(TwbLStringType) do if Assigned(tables[k]) then begin
        path := root + tables[k].Name;
        if textExport then path := path + '.txt';
        row := Result.A['outputs'].AddObject;
        row.S['path'] := path;
        row.S['status'] := 'attempting';
        try
          xeAutomationAtomicWrite(path, streams[k], overwrite);
          row.S['status'] := 'written';
          if not textExport then tables[k].Modified := False;
        except
          on E: Exception do begin
            row.S['status'] := 'failed'; row.S['message'] := E.Message;
            if (E is ExeAutomationError) and Assigned(ExeAutomationError(E).Details) then
              row.O['details'].Assign(ExeAutomationError(E).Details);
            Result.B['partial'] := Result.A['outputs'].Count > 1;
            xeAutomationWriteLocalizationDirtyState(Result);
            Exit;
          end;
        end;
      end;
      Result.B['complete'] := True;
      xeAutomationWriteLocalizationDirtyState(Result);
    except Result.Free; raise; end;
  finally
    for k := Low(TwbLStringType) to High(TwbLStringType) do streams[k].Free;
  end;
end;

function SaveTables(const AArgs: TJsonObject): TJsonObject;
begin Result := OutputTables(AArgs, False); end;
function ExportText(const AArgs: TJsonObject): TJsonObject;
begin Result := OutputTables(AArgs, True); end;

procedure xeAutomationRegisterLocalizationCommands;
begin
  xeAutomationRegisterCommand('localization.tables', Tables);
  xeAutomationRegisterCommand('localization.get', GetString);
  xeAutomationRegisterCommand('localization.set', SetString);
  xeAutomationRegisterCommand('localization.language', Language);
  xeAutomationRegisterCommand('localization.convert', Convert);
  xeAutomationRegisterCommand('localization.save', SaveTables);
  xeAutomationRegisterCommand('localization.export_text', ExportText);
end;
end.
