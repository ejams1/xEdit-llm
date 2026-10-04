{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationRecordQueries;

interface

uses JsonDataObjects, xeAutomationDataLookup;

function xeAutomationRecordQueryPage(const AKind: string; const AArgs: TJsonObject;
  const AMetadata: TJsonObject): TxeAutomationMainRecords;
procedure xeAutomationInvalidateRecordQueries;
procedure xeAutomationVerifyRecordQueryRevision(const AMetadata: TJsonObject);
function xeAutomationQuerySemanticRevision: UInt64;

implementation

uses Windows, SysUtils, Generics.Collections, wbInterface, wbHelpers, wbLoadOrder, wbImplementation,
  xeAutomationErrors, xeAutomationObjectModel, xeAutomationCommandsReachability;

const
  MaxCursors = 32;
  MaxVisited = 100000;
  CursorLifetimeMs = 300000;
  MaxScannedPerPage = 5000;
  MaxRetainedBytes = 64 * 1024 * 1024;

type
  TxeQueryFrame = record
    Element: IwbElement;
    NextChild: Integer;
    Visited: Boolean;
  end;
  TxeRecordQuery = class
    Kind, Query, Token, IncompleteReason: string;
    Revision, Touched: UInt64;
    RetainedBytes: Int64;
    Filter: TxeAutomationRecordFilter;
    FileIndex, RecordIndex, Skip, Emitted, Visited: Integer;
    Root: IwbMainRecord;
    Roots: TDynMainRecords;
    RootIndex: Integer;
    Frames: TList<TxeQueryFrame>;
    Seen: TDictionary<string, Boolean>;
    PendingHit: IwbMainRecord;
    Done, Incomplete: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Next(out ARecord: IwbMainRecord): Boolean;
  end;

var
  Cursors: TObjectDictionary<string, TxeRecordQuery>;
  TotalRetainedBytes: Int64;
  SemanticRevision: UInt64;

constructor TxeRecordQuery.Create;
begin
  inherited;
  Frames := TList<TxeQueryFrame>.Create;
  Seen := TDictionary<string, Boolean>.Create;
  Revision := wbGlobalModifedGeneration;
  Touched := GetTickCount64;
  RetainedBytes := 16384; // Covers bounded stack and object overhead.
  Inc(TotalRetainedBytes, RetainedBytes);
end;

destructor TxeRecordQuery.Destroy;
begin
  Dec(TotalRetainedBytes, RetainedBytes);
  Frames.Free;
  Seen.Free;
  inherited;
end;

procedure xeAutomationInvalidateRecordQueries;
begin
  // Called at graph teardown and semantic/index changes whose order can change
  // without a plugin mutation generation. Retained native interfaces are released.
  if Assigned(Cursors) then
    Cursors.Clear;
  Inc(SemanticRevision);
end;

function xeAutomationQuerySemanticRevision: UInt64;
begin
  Result := SemanticRevision;
end;

procedure xeAutomationVerifyRecordQueryRevision(const AMetadata: TJsonObject);
begin
  // Summary serialization may itself trigger native lazy work. A continuation
  // must never carry the earlier graph revision after that work completes.
  if AMetadata.S['revision'] <> UIntToStr(wbGlobalModifedGeneration) then begin
    xeAutomationInvalidateRecordQueries;
    raise xeAutomationNewError('cursor_invalidated', 'Loaded graph changed while serializing the page');
  end;
end;

function TxeRecordQuery.Next(out ARecord: IwbMainRecord): Boolean;
var
  lFile: IwbFile;
  lFrame: TxeQueryFrame;
  lContainer: IwbContainer;
  lElement, lLinked: IwbElement;
begin
  Result := False;
  ARecord := nil;
  if Kind = 'references' then begin
    if Frames.Count = 0 then begin
      if RootIndex >= Length(Roots) then begin
        Done := True;
        Exit;
      end;
      lFrame.Element := Roots[RootIndex];
      lFrame.NextChild := 0;
      lFrame.Visited := False;
      Frames.Add(lFrame);
      Inc(RootIndex);
    end;
    lFrame := Frames.Last;
    if not lFrame.Visited then begin
      lFrame.Visited := True;
      Frames[Frames.Count - 1] := lFrame;
      if lFrame.Element.CanContainFormIDs then begin
        lLinked := lFrame.Element.LinksTo;
        if Assigned(lLinked) then
          ARecord := lLinked.ContainingMainRecord;
      end;
      Exit(True);
    end;
    if lFrame.Element.CanContainFormIDs and Supports(lFrame.Element, IwbContainer, lContainer) and
       (lFrame.NextChild < lContainer.ElementCount) then begin
      lElement := lContainer.Elements[lFrame.NextChild];
      Inc(lFrame.NextChild);
      Frames[Frames.Count - 1] := lFrame;
      if Frames.Count >= 128 then begin
        Incomplete := True;
        IncompleteReason := 'relationship_depth_limit';
        Exit;
      end;
      lFrame.Element := lElement;
      lFrame.NextChild := 0;
      lFrame.Visited := False;
      Frames.Add(lFrame);
    end else
      Frames.Delete(Frames.Count - 1);
    Exit(True);
  end;
  if Kind = 'referenced_by' then begin
    if RecordIndex >= Root.ReferencedByCount then begin
      Done := True;
      Exit;
    end;
    ARecord := Root.ReferencedBy[RecordIndex];
    Inc(RecordIndex);
    Exit(True);
  end;
  while FileIndex < Length(Filter.Files) do begin
    lFile := Filter.Files[FileIndex];
    if RecordIndex >= lFile.RecordCount then begin
      Inc(FileIndex);
      RecordIndex := 0;
      Continue;
    end;
    Supports(lFile.Records[RecordIndex], IwbMainRecord, ARecord);
    Inc(RecordIndex);
    if Assigned(ARecord) and not xeAutomationRecordMatchesFilter(ARecord, Filter) then
      ARecord := nil;
    if Filter.Incomplete then begin
      Incomplete := True;
      IncompleteReason := Filter.IncompleteReason;
    end;
    Exit(True);
  end;
  Done := True;
end;

function QueryIdentity(const AKind: string; const AArgs: TJsonObject): string;
var
  lQuery: TJsonObject;
begin
  lQuery := AArgs.Clone;
  try
    lQuery.Remove('cursor');
    // Projection and page size also belong to the exact query contract.
    Result := AKind + ':' + lQuery.ToJSON(False);
  finally
    lQuery.Free;
  end;
end;

procedure RequireReferenceIndex;
var
  lModule: PwbModuleInfo;
  lFile: IwbFile;
begin
  {$IFDEF USE_PARALLEL_BUILD_REFS}
  if wbBuildingRefsParallel then
    raise xeAutomationStateConflict('Reverse references are still being built');
  {$ENDIF}
  for lModule in wbModulesByLoadOrder do begin
    lFile := nil;
    if mfHasFile in lModule.miFlags then lFile := lModule._File;
    if Assigned(lFile) and not wbAutomationReferenceIndexIsCurrent(lFile) then
      raise xeAutomationStateConflict('Reverse references require a complete loaded-file reference index; build it first');
  end;
end;

function NewQuery(const AKind: string; const AArgs: TJsonObject): TxeRecordQuery;
var
  lArgs: TJsonObject;
  lRecursive, lSpecified: Boolean;
  lChildren: TDynMainRecords;
  i: Integer;
begin
  Result := TxeRecordQuery.Create;
  try
    Result.Kind := AKind;
    Result.Query := QueryIdentity(AKind, AArgs);
    Result.Skip := xeAutomationReadOffsetArg(AArgs);
    if (AKind = 'references') or (AKind = 'referenced_by') then begin
      Result.Root := xeAutomationRequireMainRecord(xeAutomationParseLocator(AArgs, True, False));
      if xeAutomationReadStringArg(AArgs, 'path') <> '' then
        raise xeAutomationInvalidRequest('Relationship query must address a record root');
      if AKind = 'referenced_by' then
        RequireReferenceIndex
      else begin
        SetLength(Result.Roots, 1);
        Result.Roots[0] := Result.Root;
        lRecursive := xeAutomationReadBooleanArg(AArgs, 'recursive', lSpecified);
        if lRecursive and Assigned(Result.Root.ChildGroup) then begin
          // Preserve existing semantics: recurse through native sibling-selected
          // child-group records, never through the transitive reference graph.
          lChildren := wbGetSiblingRecords(Result.Root,
            wbStringToSignatures('REFR,ACHR,PGRE,PHZD,PARW,PBAR,PBEA,PCON,PFLA,PMIS,LAND,NAVM,PGRD,INFO,DLBR,SCEN,CELL,DIAL,QUST,WRLD'), True);
          if Length(lChildren) > MaxVisited then
            raise xeAutomationInvalidRequest('Recursive relationship roots exceed the query limit');
          SetLength(Result.Roots, Length(lChildren) + 1);
          for i := Low(lChildren) to High(lChildren) do
            Result.Roots[i + 1] := lChildren[i];
        end;
      end;
    end else begin
      if AKind = 'list' then
        lArgs := TJsonObject.Create
      else
        lArgs := AArgs.Clone;
      try
        if AKind = 'list' then begin
          lArgs.A['files'].Add(xeAutomationRequireStringArg(AArgs, 'file'));
          if xeAutomationReadStringArg(AArgs, 'signature') <> '' then
            lArgs.A['signatures'].Add(AArgs.S['signature']);
        end;
        lArgs.I['limit'] := 100;
        Result.Filter := xeAutomationReadRecordFilter(lArgs);
        if Result.Filter.HasNotReachable and not xeAutomationReachabilityIsCurrent then
          raise xeAutomationStateConflict('notReachable requires a successful current analysis.reachability pass; rerun after graph changes');
        if Result.Filter.HasUnnecessaryPersistent or Result.Filter.HasReferencesInjected then RequireReferenceIndex;
        // RequirePluginFiles already deduplicates file scope, and each native
        // Records[] index is unique. Keep ordinary scans constant-memory.
      finally
        lArgs.Free;
      end;
    end;
    Inc(Result.RetainedBytes, Length(Result.Roots) * SizeOf(Pointer) +
      Length(Result.Filter.Files) * SizeOf(Pointer) + Length(Result.Query) * 2);
    Inc(TotalRetainedBytes, Result.RetainedBytes - 16384);
    if TotalRetainedBytes > MaxRetainedBytes then
      raise xeAutomationNewError('cursor_capacity', 'Retained query state exceeds the session byte budget');
    Result.Revision := wbGlobalModifedGeneration;
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationRecordQueryPage(const AKind: string; const AArgs: TJsonObject;
  const AMetadata: TJsonObject): TxeAutomationMainRecords;
var
  lQuery: TxeRecordQuery;
  lToken, lKey: string;
  lId: TGUID;
  lLimit, lScanned: Integer;
  lDeadline: UInt64;
  lRecord: IwbMainRecord;
  lMore: Boolean;
  lExpired: TList<string>;
  lPair: TPair<string, TxeRecordQuery>;
begin
  Result := nil;
  lLimit := xeAutomationReadChildrenLimitArg(AArgs, 'limit', 100);
  if lLimit > 500 then
    raise xeAutomationInvalidRequest('Record query limit must be 1 to 500');
  lToken := xeAutomationReadStringArg(AArgs, 'cursor');
  if not Assigned(Cursors) then
    Cursors := TObjectDictionary<string, TxeRecordQuery>.Create([doOwnsValues]);
  lExpired := TList<string>.Create;
  try
    for lPair in Cursors do
      if (GetTickCount64 - lPair.Value.Touched > CursorLifetimeMs) or
         (lPair.Value.Revision <> wbGlobalModifedGeneration) then
        lExpired.Add(lPair.Key);
    for lKey in lExpired do
      Cursors.Remove(lKey);
  finally
    lExpired.Free;
  end;
  if lToken <> '' then begin
    if not Cursors.TryGetValue(lToken, lQuery) then
      raise xeAutomationNewError('cursor_invalidated', 'Cursor expired, finished or belongs to another session');
    if lQuery.Revision <> wbGlobalModifedGeneration then begin
      Cursors.Remove(lToken);
      raise xeAutomationNewError('cursor_invalidated', 'Loaded plugin mutation invalidated the cursor');
    end;
    if lQuery.Query <> QueryIdentity(AKind, AArgs) then
      raise xeAutomationInvalidRequest('Cursor continuation must preserve the original query arguments');
    if AKind = 'referenced_by' then
      RequireReferenceIndex;
    if AKind = 'filter' then begin
      if lQuery.Filter.HasNotReachable and not xeAutomationReachabilityIsCurrent then
        raise xeAutomationStateConflict('Reachability changed; rerun analysis.reachability and restart the filter');
      if lQuery.Filter.HasUnnecessaryPersistent or lQuery.Filter.HasReferencesInjected then RequireReferenceIndex;
    end;
  end else begin
    if Cursors.Count >= MaxCursors then
      raise xeAutomationNewError('cursor_capacity', 'Finish existing queries or wait for cursor expiry');
    lQuery := NewQuery(AKind, AArgs);
    CreateGUID(lId);
    lToken := GUIDToString(lId);
    lQuery.Token := lToken;
    Cursors.Add(lToken, lQuery);
  end;
  lQuery.Touched := GetTickCount64;
  lQuery.Filter.RegexDeadline := GetTickCount64 + 250;
  lQuery.Filter.RegexMatchAttempts := 0;
  lQuery.Filter.ElementVisits := 0;
  lQuery.Filter.RegexTimeouts := 0;
  lQuery.Filter.RegexSlotsExhausted := 0;
  lDeadline := GetTickCount64 + 100;
  lScanned := 0;
  try
    while not lQuery.Done and not lQuery.Incomplete do begin
      if Assigned(lQuery.PendingHit) then begin
        lRecord := lQuery.PendingHit;
        lQuery.PendingHit := nil;
      end else begin
        if (lScanned >= MaxScannedPerPage) or (GetTickCount64 >= lDeadline) then
          Break;
        if not lQuery.Next(lRecord) then
          Break;
        Inc(lScanned);
        Inc(lQuery.Visited);
        if (lQuery.Kind = 'references') and (lQuery.Visited > MaxVisited) then begin
          lQuery.Incomplete := True;
          lQuery.IncompleteReason := 'query_visit_limit';
          Break;
        end;
        if lQuery.Incomplete then
          Break; // This candidate's regex outcome is unknown, never a nonmatch.
        if not Assigned(lRecord) then
          Continue;
        lKey := LowerCase(lRecord._File.FileName) + ':' + lRecord.LoadOrderFormID.ToString(False);
        if (lQuery.Kind = 'references') or (lQuery.Kind = 'referenced_by') then begin
          if lQuery.Seen.ContainsKey(lKey) then
            Continue;
          if (Length(lKey) > 1024) or
             (TotalRetainedBytes + Length(lKey) * 2 + 96 > MaxRetainedBytes) then begin
            lQuery.Incomplete := True;
            lQuery.IncompleteReason := 'query_retention_limit';
            Break;
          end;
          lQuery.Seen.Add(lKey, True);
          Inc(lQuery.RetainedBytes, Length(lKey) * 2 + 96);
          Inc(TotalRetainedBytes, Length(lKey) * 2 + 96);
        end;
        if lQuery.Skip > 0 then begin
          Dec(lQuery.Skip);
          Continue;
        end;
      end;
      if Length(Result) >= lLimit then begin
        lQuery.PendingHit := lRecord;
        Break;
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := lRecord;
      Inc(lQuery.Emitted);
    end;
    if lQuery.Revision <> wbGlobalModifedGeneration then
      raise xeAutomationNewError('cursor_invalidated', 'Native lazy reads changed the loaded graph; restart the query');
    lMore := not lQuery.Done and not lQuery.Incomplete;
    AMetadata.B['complete'] := lQuery.Done and not lQuery.Incomplete;
    AMetadata.B['truncated'] := lMore;
    AMetadata.B['incomplete'] := lQuery.Incomplete;
    AMetadata.S['revision'] := UIntToStr(lQuery.Revision);
    AMetadata.I['limit'] := lLimit;
    AMetadata.I['scanned'] := lScanned;
    AMetadata.I['scannedTotal'] := lQuery.Visited;
    AMetadata.I['emittedTotal'] := lQuery.Emitted;
    AMetadata.I['regexTimeouts'] := lQuery.Filter.RegexTimeouts;
    AMetadata.I['regexSlotsExhausted'] := lQuery.Filter.RegexSlotsExhausted;
    if lQuery.Incomplete then
      AMetadata.S['incompleteReason'] := lQuery.IncompleteReason;
    if lMore then begin
      // A page token is consumed once. Lost-response retries must use the exact
      // request and an idempotency key; reusing an old token cannot skip a page.
      Cursors.ExtractPair(lToken);
      CreateGUID(lId);
      lToken := GUIDToString(lId);
      Cursors.Add(lToken, lQuery);
      AMetadata.S['nextCursor'] := lToken;
      AMetadata.S['continuationReason'] := 'page_or_scan_budget';
    end
    else
      Cursors.Remove(lToken);
  except
    Cursors.Remove(lToken);
    raise;
  end;
end;

finalization
  Cursors.Free;
end.
