{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationCommandsComparisons;
interface
procedure xeAutomationRegisterComparisonCommands;
implementation
uses Classes, SysUtils, TypInfo, JsonDataObjects, VirtualTrees, wbInterface,
  wbImplementation, wbLoadOrder, xeMainForm, xeAutomationDataLookup,
  xeAutomationErrors, xeAutomationObjectModel, xeAutomationValues,
  xeAutomationRecordQueries, xeAutomationMutationAudit, xeAutomationMutationPolicy,
  xeAutomationRegistry;

const MaxScope = 2048; MaxInput = 67108864; MaxResponse = 1048576;
type
  TComparisonAccess = class(TfrmMain)
  public
    procedure Children(const AData: PViewNodeDatas; ACount: Integer; var AChildren: Cardinal);
    procedure Row(const AData, AParent: PViewNodeDatas; ACount: Integer; AIndex: Cardinal;
      var AStates: TVirtualNodeInitStates);
  end;

procedure TComparisonAccess.Children(const AData: PViewNodeDatas; ACount: Integer; var AChildren: Cardinal);
begin InitChildren(AData, ACount, AChildren); end;
procedure TComparisonAccess.Row(const AData, AParent: PViewNodeDatas; ACount: Integer;
  AIndex: Cardinal; var AStates: TVirtualNodeInitStates);
begin InitNodes(nil, AData, AParent, ACount, AIndex, AStates); end;

procedure CheckMode;
begin
  if wbIsMorrowind or wbTranslationMode then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
      'Comparisons require numeric plugin records with translation mode off');
end;

procedure BoundScope(const AElement: IwbElement; ADepth: Integer; var AVisits: Integer);
var C: IwbContainer; i: Integer;
begin
  Inc(AVisits);
  if (AVisits > MaxScope) or (ADepth > 16) then
    raise xeAutomationNewError('comparison_capacity', 'Comparison source scope exceeds 2048 visits or depth16');
  if Supports(AElement, IwbContainer, C) then begin
    if C.ElementCount > MaxScope - AVisits then
      raise xeAutomationNewError('comparison_capacity', 'Comparison container exceeds remaining source budget');
    for i := 0 to C.ElementCount - 1 do BoundScope(C.Elements[i], ADepth + 1, AVisits);
  end;
end;

procedure Locator(const J: TJsonObject; const R: IwbMainRecord; const E: IwbElement);
begin
  J.S['file'] := R._File.FileName; J.S['formId'] := R.LoadOrderFormID.ToString(False);
  J.S['path'] := xeAutomationElementLocatorPath(E);
end;

function CompareRecords(const AArgs: TJsonObject): TJsonObject;
var
  Records: TDynMainRecords; Roots: TDynViewNodeDatas; Inputs: TJsonArray;
  Access: TComparisonAccess; Path, Revision: string; Visits, Limit, Depth, i, j: Integer;
  L: TxeAutomationLocator; E: IwbElement; Column: TJsonObject;
  ScopeStates: TVirtualNodeInitStates;

  procedure Emit(const Data: TDynViewNodeDatas; const Key: string; Level: Integer;
    const States: TVirtualNodeInitStates);
  var RowJson, Cell: TJsonObject; Element: IwbElement; k: Integer; Conflict: TConflictAll;
  begin
    if Result.A['rows'].Count >= Limit then begin
      Result.B['complete'] := False; Result.S['incompleteReason'] := 'row-limit'; Exit;
    end;
    RowJson := Result.A['rows'].AddObject; RowJson.S['alignedPath'] := Key;
    RowJson.I['depth'] := Level; RowJson.B['hasChildren'] := ivsHasChildren in States;
    // Container conflict evaluation recursively walks the entire subtree. Leaf
    // classification is bounded here; presence and exact values are independent.
    if not (ivsHasChildren in States) then begin
      Conflict := Access.ConflictLevelForNodeDatas(@Data[0], Length(Data), True, False);
      RowJson.S['siblingConflictAll'] := GetEnumName(TypeInfo(TConflictAll), Ord(Conflict));
    end;
    for k := 0 to High(Data) do begin
      Cell := RowJson.A['cells'].AddObject; Cell.I['column'] := k;
      Element := Data[k].Element;
      Cell.B['present'] := Assigned(Element) or (vnfDontShow in Data[k].ViewNodeFlags);
      Cell.B['visible'] := Assigned(Element);
      Cell.B['ignored'] := vnfIgnore in Data[k].ViewNodeFlags;
      if not (ivsHasChildren in States) then
        Cell.S['siblingConflictThis'] := GetEnumName(TypeInfo(TConflictThis), Ord(Data[k].ConflictThis));
      if vnfDontShow in Data[k].ViewNodeFlags then Cell.S['state'] := 'hidden'
      else if Assigned(Element) then Cell.S['state'] := 'present'
      else if vnfIsPartialForm in Data[k].ViewNodeFlags then Cell.S['state'] := 'partial-ignored'
      else Cell.S['state'] := 'missing';
      if Assigned(Element) then begin
        Locator(Cell.O['locator'], Records[k], Element);
        Cell.S['name'] := Element.Name;
        if not RowJson.Contains('name') then RowJson.S['name'] := Element.Name;
        if not (ivsHasChildren in States) and Assigned(Element.ValueDef) then
          xeAutomationWriteFullValues(Cell.O['values'], Element);
      end;
    end;
    if TEncoding.UTF8.GetByteCount(Result.ToJSON(False)) > MaxResponse then
      raise xeAutomationNewError('result_too_large', 'Comparison exceeds 1MiB; narrow path or rowLimit');
  end;

  procedure Walk(var Parent: TDynViewNodeDatas; const Key: string; Level: Integer);
  var Count, Index: Cardinal; Data: TDynViewNodeDatas; States: TVirtualNodeInitStates;
      Header: Boolean; k: Integer; RowKey: string;
  begin
    if Level > Depth then begin
      Result.B['complete'] := False;
      if not Result.Contains('incompleteReason') then Result.S['incompleteReason'] := 'depth-limit';
      Exit;
    end;
    Count := 0; Access.Children(@Parent[0], Length(Parent), Count);
    if Count > MaxScope then raise xeAutomationNewError('comparison_capacity', 'Native aligned row count exceeds 2048');
    if Count = 0 then Exit;
    for Index := 0 to Count - 1 do begin
      if Result.A['rows'].Count >= Limit then begin
        Result.B['complete'] := False; Result.S['incompleteReason'] := 'row-limit'; Exit;
      end;
      Data := nil; SetLength(Data, Length(Parent)); States := [];
      Access.Row(@Data[0], @Parent[0], Length(Parent), Index, States);
      // Header scope is explicit: default record comparison emits payload only.
      Header := False;
      if (Path = '') and (Level = 0) then
        for k := 0 to High(Data) do
          if Assigned(Data[k].Element) and
             Data[k].Element.Equals(Records[k].ElementByPath['Record Header']) then Header := True;
      if Header then Continue;
      // Preserve all-hidden rows: native visibility is not proof of absence.
      RowKey := Key + '/' + IntToStr(Index);
      Emit(Data, RowKey, Level, States);
      if ivsHasChildren in States then Walk(Data, RowKey, Level + 1);
    end;
  end;

begin
  CheckMode;
  if not Assigned(frmMain) then raise xeAutomationStateConflict('Comparison requires a loaded main form');
  Revision := UIntToStr(wbGlobalModifedGeneration);
  if not AArgs.Contains('records') or (AArgs.Types['records'] <> jdtArray) then
    raise xeAutomationInvalidRequest('records must be an array of owned root locators');
  Inputs := AArgs.A['records'];
  if (Inputs.Count < 2) or (Inputs.Count > 8) then
    raise xeAutomationInvalidRequest('Comparison requires 2..8 records');
  Limit := 256; Depth := 8;
  if AArgs.Contains('rowLimit') then begin
    if AArgs.Types['rowLimit'] <> jdtInt then raise xeAutomationInvalidRequest('rowLimit must be integer');
    Limit := AArgs.I['rowLimit'];
  end;
  if AArgs.Contains('depth') then begin
    if AArgs.Types['depth'] <> jdtInt then raise xeAutomationInvalidRequest('depth must be integer');
    Depth := AArgs.I['depth'];
  end;
  if (Limit < 1) or (Limit > 256) or (Depth < 0) or (Depth > 8) then
    raise xeAutomationInvalidRequest('rowLimit must be 1..256 and depth 0..8');
  Path := xeAutomationReadStringArg(AArgs, 'path');
  SetLength(Records, Inputs.Count); SetLength(Roots, Inputs.Count); Visits := 0;
  for i := 0 to Inputs.Count - 1 do begin
    if Inputs.Types[i] <> jdtObject then raise xeAutomationInvalidRequest('Record locator must be object');
    L := xeAutomationParseLocator(Inputs.O[i], True, False);
    if L.Path <> '' then raise xeAutomationInvalidRequest('records must address roots; use common path for row scope');
    Records[i] := xeAutomationRequireOwnedMainRecord(L);
    if (Records[i].Signature = 'TES4') or ((i > 0) and not Records[0].Def.Equals(Records[i].Def)) then
      raise xeAutomationInvalidTarget('Compare matching native record definitions, excluding TES4 headers');
    for j := 0 to i - 1 do
      if Records[j].Equals(Records[i]) then raise xeAutomationInvalidRequest('Duplicate comparison record');
    if Path = '' then E := Records[i] else E := Records[i].ElementByPath[Path];
    Roots[i].Element := E;
    Supports(E, IwbContainerElementRef, Roots[i].Container);
    if Assigned(E) then BoundScope(E, 0, Visits);
    if (Path <> '') and Assigned(E) and E.DontShow then begin
      Include(Roots[i].ViewNodeFlags, vnfDontShow);
      Roots[i].Element := nil; Roots[i].Container := nil;
    end;
    if (Path <> '') and not Assigned(E) and Records[i].IsPartialForm then begin
      Include(Roots[i].ViewNodeFlags, vnfIgnore);
      Include(Roots[i].ViewNodeFlags, vnfIsPartialForm);
    end;
  end;
  // Native alignment changes derived SortOrder. Guard lazy initialization too:
  // a malformed source must not be reported as a clean read after native repair.
  Access := TComparisonAccess(frmMain);
  Result := TJsonObject.Create;
  try
    Result.S['scope'] := 'explicit-record-columns-payload'; Result.S['path'] := Path;
    Result.S['persistence'] := 'read-only-plugin-data; derived-session-alignment';
    Result.S['classification'] := 'native-sibling-leaf-conflict; not override-chain status or byte equality';
    Result.B['complete'] := True; Result.A['rows'].Clear;
    for i := 0 to High(Records) do begin
      Column := Result.A['columns'].AddObject; Column.I['index'] := i;
      Locator(Column.O['record'], Records[i], Records[i]);
      Column.B['scopePresent'] := Assigned(Roots[i].Element) or (vnfDontShow in Roots[i].ViewNodeFlags);
    end;
    if Path = '' then Walk(Roots, '', 0)
    else begin
      ScopeStates := [];
      for i := 0 to High(Roots) do
        if Assigned(Roots[i].Container) and (Roots[i].Container.ElementCount > 0) then
          Include(ScopeStates, ivsHasChildren);
      Emit(Roots, '', 0, ScopeStates);
      if ivsHasChildren in ScopeStates then Walk(Roots, '', 1);
    end;
    Result.S['mutationRevision'] := UIntToStr(wbGlobalModifedGeneration);
    if Revision <> Result.S['mutationRevision'] then
      raise xeAutomationStateConflict('Native comparison changed plugin data; inspect dirty state before retry');
  except Result.Free; raise; end;
end;

function LoadComparison(const AArgs: TJsonObject): TJsonObject;
var
  Source, Loaded, Master: IwbFile; Modules: TwbModuleInfos;
  InputPath, Name, LogicalPath, MasterName, Denied: string;
  Bytes: TBytes; Stream: TFileStream; Masters: TStringList;
  HeaderSize, HeaderEnd, Offset, Size, i, j, RecordCount, LoadedCount: Integer;
  Flags: Cardinal; DryRun, Specified: Boolean;
  Snapshot: TxeAutomationMutationSnapshot;
  Summary: TJsonObject; FoundHeader: Boolean;

  function U32(P: Integer): Cardinal;
  begin
    if (P < 0) or (P > Length(Bytes) - 4) then
      raise xeAutomationInvalidTarget('Truncated comparison structure');
    Move(Bytes[P], Result, 4);
  end;

  function Signature(P: Integer): string;
  begin
    U32(P); Result := TEncoding.ASCII.GetString(Bytes, P, 4);
  end;

  procedure ScanRecords(Start, Stop, Level: Integer);
  var P, Finish: Integer; LengthField: Cardinal;
  begin
    if Level > 16 then raise xeAutomationInvalidTarget('Comparison group depth exceeds 16');
    P := Start;
    while P < Stop do begin
      if Stop - P < HeaderSize then raise xeAutomationInvalidTarget('Truncated record/group header');
      LengthField := U32(P + 4);
      if Signature(P) = 'GRUP' then begin
        if (LengthField < Cardinal(HeaderSize)) or (LengthField > Cardinal(Stop - P)) then
          raise xeAutomationInvalidTarget('Invalid comparison group size');
        Finish := P + Integer(LengthField);
        ScanRecords(P + HeaderSize, Finish, Level + 1);
      end else begin
        if LengthField > Cardinal(Stop - P - HeaderSize) then
          raise xeAutomationInvalidTarget('Invalid comparison record size');
        Finish := P + HeaderSize + Integer(LengthField);
        Inc(RecordCount);
        if RecordCount > 1000 then
          raise xeAutomationNewError('comparison_capacity', 'Comparison contains more than 1000 records');
      end;
      P := Finish;
    end;
  end;

begin
  CheckMode;
  if not Assigned(frmMain) then raise xeAutomationStateConflict('Comparison load requires a loaded session');
  DryRun := xeAutomationReadBooleanArg(AArgs, 'dryRun', Specified);
  if not Specified then DryRun := True;
  // Loading does not edit plugins, but native Scan registers records in live
  // override chains. Consent gates that irreversible-until-restart session effect.
  if not DryRun and not xeAutomationMutationPolicyConsentSatisfied(Denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('comparisons.load', 'session-comparison-load', Denied));
  Source := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'sourceFile'));
  if Source.IsLocalized or (Source.ModuleType <> mtFull) or
     (fsIsCompareLoad in Source.FileStates) then
    raise xeAutomationInvalidTarget('Baseline must be an ordinary full nonlocalized plugin');
  InputPath := xeAutomationRequireStringArg(AArgs, 'inputPath');
  if not SameText(ExpandFileName(InputPath), InputPath) then
    raise xeAutomationInvalidRequest('inputPath must be absolute and normalized');
  if not FileExists(InputPath) or not wbIsModule(InputPath) then
    raise xeAutomationInvalidTarget('inputPath must identify an existing plugin');
  Name := xeAutomationRequireStringArg(AArgs, 'fileName');
  if (Length(Name) > 128) or (ExtractFileName(Name) <> Name) or
     (Pos('..', Name) > 0) or not SameText(ExtractFileExt(Name), '.esp') then
    raise xeAutomationInvalidRequest('fileName must be a new simple .esp name (<=128 characters)');
  for i := 1 to Length(Name) do
    if CharInSet(Name[i], ['<', '>', ':', '"', '|', '?', '*', '/', '\']) or (Ord(Name[i]) < 32) then
      raise xeAutomationInvalidRequest('fileName contains invalid filename characters');
  LogicalPath := IncludeTrailingPathDelimiter(wbDataPath) + Name;
  // Keep the native master lookup rooted in Data without creating a disk file.
  // FilesMap ignores aCompareTo on hits, so reject every existing logical identity.
  if FileExists(LogicalPath) or wbModuleByName(Name).IsValid or
     Assigned(xeAutomationTryPluginFile(Name)) then
    raise xeAutomationStateConflict('Comparison name exists on disk or in the module/session inventory');
  if FileExists(ChangeFileExt(InputPath, '.cpoverride')) or
     FileExists(ChangeFileExt(LogicalPath, '.cpoverride')) then
    raise xeAutomationInvalidTarget('Comparison encoding sidecars require their original lookup identity and are unsupported');
  Modules := wbModulesByLoadOrder; LoadedCount := 0;
  for i := Low(Modules) to High(Modules) do begin
    Master := xeAutomationTryPluginFileFromModule(Modules[i]);
    if Assigned(Master) then begin
      if SameText(ExpandFileName(Master.FileNameOnDisk), InputPath) then
        raise xeAutomationInvalidTarget('Input already belongs to a loaded file; compare its records directly');
      if fsIsCompareLoad in Master.FileStates then Inc(LoadedCount);
    end;
  end;
  if LoadedCount >= 4 then raise xeAutomationNewError('comparison_capacity', 'At most four comparisons per session');
  HeaderSize := wbSizeOfMainRecordStruct;
  if not (HeaderSize in [20, 24]) then raise xeAutomationInvalidTarget('Unsupported native plugin header size');
  // Capture once under deny-write sharing; both preflight and native loading use
  // the same bytes, rather than reopening a path after dependency validation.
  Stream := TFileStream.Create(InputPath, fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size < HeaderSize) or (Stream.Size > MaxInput) then
      raise xeAutomationInvalidTarget('Comparison input must have a complete header and be <=64MiB');
    SetLength(Bytes, Integer(Stream.Size)); Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally Stream.Free; end;
  if Signature(0) <> 'TES4' then raise xeAutomationInvalidTarget('Expected TES4 plugin header');
  if (U32(4) > 1048576) or (U32(4) > Cardinal(Length(Bytes) - HeaderSize)) then
    raise xeAutomationInvalidTarget('Invalid or oversized TES4 header payload');
  Flags := U32(8);
  if (Flags and not Cardinal(1)) <> 0 then
    raise xeAutomationInvalidTarget('Initial comparison loader supports full nonlocalized modules with only the optional ESM header flag');
  HeaderEnd := HeaderSize + Integer(U32(4)); Offset := HeaderSize; FoundHeader := False;
  Masters := TStringList.Create;
  try
    while Offset < HeaderEnd do begin
      if HeaderEnd - Offset < 6 then raise xeAutomationInvalidTarget('Truncated TES4 subrecord');
      Size := Bytes[Offset + 4] or (Integer(Bytes[Offset + 5]) shl 8);
      if Size > HeaderEnd - Offset - 6 then raise xeAutomationInvalidTarget('TES4 subrecord exceeds header');
      if Signature(Offset) = 'XXXX' then
        raise xeAutomationInvalidTarget('Extended TES4 header subrecords are unsupported');
      if Signature(Offset) = 'HEDR' then begin
        if FoundHeader or (Size <> 12) then raise xeAutomationInvalidTarget('Invalid HEDR');
        FoundHeader := True;
      end;
      if Signature(Offset) = 'MAST' then begin
        if (Size < 2) or (Bytes[Offset + 5 + Size] <> 0) then
          raise xeAutomationInvalidTarget('Invalid MAST filename');
        for j := Offset + 6 to Offset + 4 + Size do
          if (Bytes[j] < 32) or (Bytes[j] > 126) then
            raise xeAutomationInvalidTarget('Comparison MAST names must be printable ASCII without embedded NUL');
        MasterName := TEncoding.ASCII.GetString(Bytes, Offset + 6, Size - 1);
        if ExtractFileName(MasterName) <> MasterName then
          raise xeAutomationInvalidTarget('Comparison dependencies must be simple filenames');
        Master := xeAutomationRequirePluginFile(MasterName);
        if (Master.LoadOrder >= Source.LoadOrder) or (Master.ModuleType <> mtFull) or
           (fsIsCompareLoad in Master.FileStates) then
          raise xeAutomationInvalidTarget('Every dependency must be an ordinary full plugin loaded before baseline');
        if Masters.IndexOf(Master.FileName) >= 0 then raise xeAutomationInvalidTarget('Duplicate MAST dependency');
        Masters.Add(Master.FileName);
      end;
      Inc(Offset, 6 + Size);
    end;
    if not FoundHeader then raise xeAutomationInvalidTarget('Missing HEDR');
    if Masters.Count + 1 > Succ(TwbFileID.MaxFullSlot) then
      raise xeAutomationNewError('comparison_capacity', 'Comparison plus baseline exceeds native master capacity');
    RecordCount := 0; ScanRecords(0, Length(Bytes), 0);
    Result := TJsonObject.Create;
    try
      Result.B['dryRun'] := DryRun; Result.B['loaded'] := False;
      Result.B['complete'] := DryRun;
      Result.S['sourceFile'] := Source.FileName; Result.S['inputPath'] := InputPath;
      Result.S['fileName'] := Name; Result.I['inputRecordsIncludingHeader'] := RecordCount;
      Result.S['persistence'] := 'captured bytes in session only; no disk copy; restart removes comparison';
      Result.S['sessionEffect'] := 'native override/injection chains include comparison records; conflict queries may change';
      Result.B['editable'] := False; Result.B['unloadSupported'] := False;
      for i := 0 to Masters.Count - 1 do Result.A['requiredMasters'].Add(Masters[i]);
      if DryRun then Exit;
      Snapshot := xeAutomationCaptureMutationSnapshot;
      try
        Loaded := wbFile(LogicalPath, Source.LoadOrder, Source.FileNameOnDisk, [fsIsTemporary], Bytes);
        if not (fsIsCompareLoad in Loaded.FileStates) or Loaded.IsEditable or
           not Assigned(Loaded.CompareToFile) or not Loaded.CompareToFile.Equals(Source) then
          raise xeAutomationStateConflict('Native load did not produce the requested read-only comparison');
        frmMain.AddFile(Loaded); Result.B['loaded'] := True; Result.B['complete'] := True;
        Summary := xeAutomationNewFileSummary(Loaded);
        try Result.O['file'].Assign(Summary); finally Summary.Free; end;
      except
        on E: Exception do begin
          // Native constructors may register override edges before raising;
          // modification generations cannot prove rollback of those edges.
          with Result.O['failure'] do begin
            S['code'] := 'comparison_load_failed'; S['message'] := E.Message;
            S['phase'] := 'native-compare-load'; B['partialKnown'] := False;
            S['remainingState'] := 'Restart session before retry: native graph may be partially registered';
          end;
        end;
      end;
      xeAutomationInvalidateRecordQueries;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], Snapshot);
    except Result.Free; raise; end;
  finally Masters.Free; end;
end;

procedure xeAutomationRegisterComparisonCommands;
begin
  xeAutomationRegisterCommand('comparisons.records', CompareRecords);
  xeAutomationRegisterCommand('comparisons.load', LoadComparison);
end;
end.
