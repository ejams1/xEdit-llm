{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationRecordQueries;

interface

uses JsonDataObjects, xeAutomationDataLookup;

const
  xeAutomationRecursiveRootLimit = 100000;
  xeAutomationRecursiveSelectionWorkLimit = 1000000;
  xeAutomationRelationshipPayloadWorkLimit = 100000;
  xeAutomationQueryPageWorkLimit = 5000;
  xeAutomationQueryPageBudgetMs = 100;

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
  CursorLifetimeMs = 300000;
  MaxRetainedBytes = 64 * 1024 * 1024;

type
  TxeReferencePhase = (qrRootPayload, qrSelectGroups, qrSortRoots, qrChildPayload, qrDone);
  TxeQueryFrame = record
    Element: IwbElement;
    NextChild: Integer;
    Visited: Boolean;
  end;
  TxeRecordQuery = class
    Kind, Query, IncompleteReason: string;
    Revision, Touched, SemanticGeneration: UInt64;
    RetainedBytes: Int64;
    Filter: TxeAutomationRecordFilter;
    FileIndex, RecordIndex, Skip, Emitted, Visited: Integer;
    Root: IwbMainRecord;
    Roots: TList<IwbMainRecord>;
    RootKeys: TDictionary<string, Integer>;
    RootSignatures: TwbSignatures;
    ParentMaster: IwbMainRecord;
    ReferencePhase: TxeReferencePhase;
    Recursive, RootStarted, SelectionComplete: Boolean;
    RootIndex, ParentOverrideIndex, PayloadVisited, SelectionWork, SelectionCandidates, SortWork: Integer;
    HeapNode, HeapEnd, HeapBuildIndex: Integer;
    HeapBuilding, HeapActive: Boolean;
    Frames: TList<TxeQueryFrame>;
    Seen: TDictionary<string, Boolean>;
    PendingHit: IwbMainRecord;
    Done, Incomplete: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure PushFrame(const element: IwbElement);
    procedure SelectRoot(const recordRef: IwbMainRecord);
    procedure SelectOne;
    procedure SortOne;
    function NextReference(out ARecord: IwbMainRecord): Boolean;
    procedure WriteReferenceProgress(const metadata: TJsonObject);
    function Next(out ARecord: IwbMainRecord): Boolean;
  end;

var
  Cursors: TObjectDictionary<string, TxeRecordQuery>;
  TotalRetainedBytes: Int64;
  SemanticRevision: UInt64;
  ActiveQueries: Integer;

constructor TxeRecordQuery.Create;
begin
  inherited;
  Frames := TList<TxeQueryFrame>.Create;
  Seen := TDictionary<string, Boolean>.Create;
  Roots := TList<IwbMainRecord>.Create;
  RootKeys := TDictionary<string, Integer>.Create;
  ParentOverrideIndex := -1;
  Revision := wbGlobalModifedGeneration;
  SemanticGeneration := SemanticRevision;
  Touched := GetTickCount64;
  RetainedBytes := 16384; // Covers bounded stack and object overhead.
  Inc(TotalRetainedBytes, RetainedBytes);
end;

destructor TxeRecordQuery.Destroy;
begin
  Dec(TotalRetainedBytes, RetainedBytes);
  Frames.Free;
  Seen.Free;
  RootKeys.Free;
  Roots.Free;
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
  if (AMetadata.S['revision'] <> UIntToStr(wbGlobalModifedGeneration)) or
     (AMetadata.S['semanticRevision'] <> UIntToStr(SemanticRevision)) then begin
    xeAutomationInvalidateRecordQueries;
    raise xeAutomationNewError('cursor_invalidated', 'Loaded graph changed while serializing the page');
  end;
end;

procedure TxeRecordQuery.PushFrame(const element: IwbElement);
var frame: TxeQueryFrame;
begin
  if not Assigned(element) then Exit;
  if Frames.Count >= 128 then begin
    Incomplete := True;
    IncompleteReason := 'relationship_depth_limit';
    Exit;
  end;
  frame.Element := element; frame.NextChild := 0; frame.Visited := False;
  Frames.Add(frame);
end;

procedure TxeRecordQuery.SelectRoot(const recordRef: IwbMainRecord);
var
  key: string;
  index, charge: Integer;
begin
  if not wbSiblingRecordMatchesSignatures(recordRef, RootSignatures) then Exit;
  Inc(SelectionCandidates);
  key := recordRef.LoadOrderFormID.ToString(False);
  if RootKeys.TryGetValue(key, index) then begin
    // Native sibling selection retains the last/highest file version within
    // these parent child groups, not an unrelated global WinningOverride.
    if CompareElementsFormIDAndLoadOrder(Pointer(IwbElement(Roots[index])),
      Pointer(IwbElement(recordRef))) < 0 then Roots[index] := recordRef;
    Exit;
  end;
  if Roots.Count >= xeAutomationRecursiveRootLimit then begin
    Incomplete := True; IncompleteReason := 'recursive_root_limit'; Exit;
  end;
  charge := Length(key) * 2 + 160; // Key/map/list capacity, including spare slots.
  if (Length(key) > 1024) or (TotalRetainedBytes + charge > MaxRetainedBytes) then begin
    Incomplete := True; IncompleteReason := 'recursive_root_retention_limit'; Exit;
  end;
  Inc(RetainedBytes, charge); Inc(TotalRetainedBytes, charge);
  RootKeys.Add(key, Roots.Count);
  Roots.Add(recordRef);
end;

procedure TxeRecordQuery.SelectOne;
var
  frame: TxeQueryFrame;
  recordRef, parent: IwbMainRecord;
  container: IwbContainerElementRef;
  child: IwbElement;
begin
  if SelectionWork >= xeAutomationRecursiveSelectionWorkLimit then begin
    Incomplete := True; IncompleteReason := 'recursive_selection_visit_limit'; Exit;
  end;
  Inc(SelectionWork);
  if Frames.Count = 0 then begin
    if ParentOverrideIndex < 0 then begin
      ParentOverrideIndex := 0;
      PushFrame(Root.ChildGroup);
      Exit;
    end;
    if not Assigned(ParentMaster) then ParentMaster := Root.MasterOrSelf;
    if ParentOverrideIndex < ParentMaster.OverrideCount then begin
      parent := ParentMaster.Overrides[ParentOverrideIndex];
      Inc(ParentOverrideIndex);
      if parent._File.LoadOrder > Root._File.LoadOrder then PushFrame(parent.ChildGroup);
      Exit;
    end;
    SelectionComplete := True;
    RootIndex := 0;
    if Roots.Count > 1 then begin
      HeapBuildIndex := Roots.Count div 2 - 1;
      HeapEnd := Roots.Count - 1;
      HeapBuilding := True; HeapActive := False;
      ReferencePhase := qrSortRoots;
    end else ReferencePhase := qrChildPayload;
    Exit;
  end;
  frame := Frames.Last;
  if not frame.Visited then begin
    frame.Visited := True; Frames[Frames.Count - 1] := frame;
    if Supports(frame.Element, IwbMainRecord, recordRef) then begin
      SelectRoot(recordRef);
      // Match native FindRecords: a main record terminates structural descent.
      // Its payload and ChildGroup are not recursively followed here.
      Frames.Delete(Frames.Count - 1);
    end;
    Exit;
  end;
  if Supports(frame.Element, IwbContainerElementRef, container) and
     (frame.NextChild < container.ElementCount) then begin
    child := container.Elements[frame.NextChild];
    Inc(frame.NextChild); Frames[Frames.Count - 1] := frame;
    PushFrame(child);
  end else Frames.Delete(Frames.Count - 1);
end;

procedure TxeRecordQuery.SortOne;
var
  child: Integer;
  saved: IwbMainRecord;

  function Compare(const left, right: Integer): Integer;
  begin
    Result := CompareElementsFormIDAndLoadOrder(Pointer(IwbElement(Roots[left])),
      Pointer(IwbElement(Roots[right])));
  end;

  procedure Swap(const left, right: Integer);
  begin
    saved := Roots[left]; Roots[left] := Roots[right]; Roots[right] := saved;
  end;
begin
  Inc(SortWork);
  // Incremental heapsort: one sift level (<=2 native comparisons and one swap)
  // or one stage transition per work unit. No whole-root sort before paging.
  if HeapActive then begin
    child := HeapNode * 2 + 1;
    if child > HeapEnd then HeapActive := False
    else begin
      if (child < HeapEnd) and (Compare(child, child + 1) < 0) then Inc(child);
      if Compare(HeapNode, child) < 0 then begin
        Swap(HeapNode, child); HeapNode := child;
      end else HeapActive := False;
    end;
  end else if HeapBuilding then begin
    if HeapBuildIndex >= 0 then begin
      HeapNode := HeapBuildIndex; Dec(HeapBuildIndex); HeapActive := True;
    end else HeapBuilding := False;
  end else if HeapEnd > 0 then begin
    Swap(0, HeapEnd); Dec(HeapEnd); HeapNode := 0; HeapActive := True;
  end else ReferencePhase := qrChildPayload;
end;

function TxeRecordQuery.NextReference(out ARecord: IwbMainRecord): Boolean;
var
  frame: TxeQueryFrame;
  container: IwbContainer;
  linked, child: IwbElement;
begin
  Result := True;
  ARecord := nil;
  case ReferencePhase of
    qrSelectGroups: begin SelectOne; Exit; end;
    qrSortRoots: begin SortOne; Exit; end;
    qrDone: begin Done := True; Exit(False); end;
  end;
  if PayloadVisited >= xeAutomationRelationshipPayloadWorkLimit then begin
    Incomplete := True; IncompleteReason := 'query_visit_limit'; Exit;
  end;
  Inc(PayloadVisited);
  if Frames.Count = 0 then begin
    if ReferencePhase = qrRootPayload then begin
      if not RootStarted then begin PushFrame(Root); RootStarted := True; end
      else begin
        if Recursive then ReferencePhase := qrSelectGroups
        else begin ReferencePhase := qrDone; Done := True; end;
        Exit;
      end;
    end else if RootIndex < Roots.Count then begin
      PushFrame(Roots[RootIndex]);
      Roots[RootIndex] := nil; // Frames own the current root; release finished slots.
      Inc(RootIndex);
    end else begin ReferencePhase := qrDone; Done := True; Exit; end;
  end;
  if Incomplete then Exit;
  frame := Frames.Last;
  if not frame.Visited then begin
    frame.Visited := True; Frames[Frames.Count - 1] := frame;
    if frame.Element.CanContainFormIDs then begin
      linked := frame.Element.LinksTo;
      if Assigned(linked) then ARecord := linked.ContainingMainRecord;
    end;
    Exit;
  end;
  if frame.Element.CanContainFormIDs and Supports(frame.Element, IwbContainer, container) and
     (frame.NextChild < container.ElementCount) then begin
    child := container.Elements[frame.NextChild];
    Inc(frame.NextChild); Frames[Frames.Count - 1] := frame;
    PushFrame(child);
  end else Frames.Delete(Frames.Count - 1);
end;

procedure TxeRecordQuery.WriteReferenceProgress(const metadata: TJsonObject);
const
  PhaseNames: array[TxeReferencePhase] of string = ('root-payload', 'select-child-roots',
    'sort-child-roots', 'child-payload', 'complete');
begin
  metadata.O['traversal'].S['phase'] := PhaseNames[ReferencePhase];
  metadata.O['traversal'].B['recursive'] := Recursive;
  metadata.O['traversal'].B['rootSelectionComplete'] := SelectionComplete or not Recursive;
  metadata.O['traversal'].I['selectedChildRoots'] := Roots.Count;
  metadata.O['traversal'].I['retainedChildRoots'] := Roots.Count - RootIndex;
  metadata.O['traversal'].I['candidateVersions'] := SelectionCandidates;
  metadata.O['traversal'].I['selectionWork'] := SelectionWork;
  metadata.O['traversal'].I['sortWork'] := SortWork;
  metadata.O['traversal'].I['payloadWork'] := PayloadVisited;
  metadata.O['traversal'].I['retainedDepth'] := Frames.Count;
  metadata.O['traversal'].L['accountedRetainedBytes'] := RetainedBytes;
  metadata.O['traversal'].I['rootLimit'] := xeAutomationRecursiveRootLimit;
  metadata.O['traversal'].I['selectionWorkLimit'] := xeAutomationRecursiveSelectionWorkLimit;
  metadata.O['traversal'].I['payloadWorkLimit'] := xeAutomationRelationshipPayloadWorkLimit;
  metadata.O['traversal'].I['pageWorkLimit'] := xeAutomationQueryPageWorkLimit;
  metadata.O['traversal'].I['softPageBudgetMs'] := xeAutomationQueryPageBudgetMs;
  metadata.O['traversal'].B['nativeCallsPreemptible'] := False;
end;

function TxeRecordQuery.Next(out ARecord: IwbMainRecord): Boolean;
var
  lFile: IwbFile;
begin
  Result := False;
  ARecord := nil;
  if Kind = 'references' then Exit(NextReference(ARecord));
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
  lSpecified: Boolean;
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
        Result.Recursive := xeAutomationReadBooleanArg(AArgs, 'recursive', lSpecified);
        Result.RootSignatures := wbStringToSignatures(xeAutomationChildGroupReferenceSignatures);
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
    Inc(Result.RetainedBytes, Length(Result.Filter.Files) * SizeOf(Pointer) + Length(Result.Query) * 2);
    Inc(TotalRetainedBytes, Result.RetainedBytes - 16384);
    if TotalRetainedBytes > MaxRetainedBytes then
      raise xeAutomationNewError('cursor_capacity', 'Retained query state exceeds the session byte budget');
    Result.Revision := wbGlobalModifedGeneration;
    Result.SemanticGeneration := SemanticRevision;
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
         (lPair.Value.Revision <> wbGlobalModifedGeneration) or
         (lPair.Value.SemanticGeneration <> SemanticRevision) then
        lExpired.Add(lPair.Key);
    for lKey in lExpired do
      Cursors.Remove(lKey);
  finally
    lExpired.Free;
  end;
  if lToken <> '' then begin
    if not Cursors.TryGetValue(lToken, lQuery) then
      raise xeAutomationNewError('cursor_invalidated', 'Cursor expired, finished or belongs to another session');
    if (lQuery.Revision <> wbGlobalModifedGeneration) or
       (lQuery.SemanticGeneration <> SemanticRevision) then begin
      Cursors.Remove(lToken);
      raise xeAutomationNewError('cursor_invalidated', 'Loaded plugin mutation invalidated the cursor');
    end;
    if lQuery.Query <> QueryIdentity(AKind, AArgs) then
      raise xeAutomationInvalidRequest('Cursor continuation must preserve the original query arguments');
    // The page owns the query while native calls execute. Invalidation can
    // clear cached queries reentrantly without freeing this active traversal.
    Cursors.ExtractPair(lToken);
  end else begin
    lQuery := nil;
    if Cursors.Count + ActiveQueries >= MaxCursors then
      raise xeAutomationNewError('cursor_capacity', 'Finish existing queries or wait for cursor expiry');
  end;
  Inc(ActiveQueries);
  try
    if not Assigned(lQuery) then lQuery := NewQuery(AKind, AArgs)
    else begin
      if AKind = 'referenced_by' then
        RequireReferenceIndex;
      if AKind = 'filter' then begin
        if lQuery.Filter.HasNotReachable and not xeAutomationReachabilityIsCurrent then
          raise xeAutomationStateConflict('Reachability changed; rerun analysis.reachability and restart the filter');
        if lQuery.Filter.HasUnnecessaryPersistent or lQuery.Filter.HasReferencesInjected then RequireReferenceIndex;
      end;
    end;
    lQuery.Touched := GetTickCount64;
    lQuery.Filter.RegexDeadline := GetTickCount64 + 250;
    lQuery.Filter.RegexMatchAttempts := 0;
    lQuery.Filter.ElementVisits := 0;
    lQuery.Filter.RegexTimeouts := 0;
    lQuery.Filter.RegexSlotsExhausted := 0;
    lDeadline := GetTickCount64 + xeAutomationQueryPageBudgetMs;
    lScanned := 0;
    while not lQuery.Done and not lQuery.Incomplete do begin
      if Assigned(lQuery.PendingHit) then begin
        lRecord := lQuery.PendingHit;
        lQuery.PendingHit := nil;
      end else begin
        if (lScanned >= xeAutomationQueryPageWorkLimit) or (GetTickCount64 >= lDeadline) then
          Break;
        if not lQuery.Next(lRecord) then
          Break;
        Inc(lScanned);
        Inc(lQuery.Visited);
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
    if (lQuery.Revision <> wbGlobalModifedGeneration) or
       (lQuery.SemanticGeneration <> SemanticRevision) then
      raise xeAutomationNewError('cursor_invalidated', 'Native reads changed the plugin/semantic revision; restart the query');
    lMore := not lQuery.Done and not lQuery.Incomplete;
    AMetadata.B['complete'] := lQuery.Done and not lQuery.Incomplete;
    AMetadata.B['truncated'] := lMore;
    AMetadata.B['incomplete'] := lQuery.Incomplete;
    AMetadata.B['cursorRetained'] := lMore;
    AMetadata.S['revision'] := UIntToStr(lQuery.Revision);
    AMetadata.S['semanticRevision'] := UIntToStr(lQuery.SemanticGeneration);
    AMetadata.I['limit'] := lLimit;
    AMetadata.I['scanned'] := lScanned;
    AMetadata.I['scannedTotal'] := lQuery.Visited;
    AMetadata.I['emittedTotal'] := lQuery.Emitted;
    AMetadata.I['regexTimeouts'] := lQuery.Filter.RegexTimeouts;
    AMetadata.I['regexSlotsExhausted'] := lQuery.Filter.RegexSlotsExhausted;
    if lQuery.Kind = 'references' then lQuery.WriteReferenceProgress(AMetadata);
    if lQuery.Incomplete then
      AMetadata.S['incompleteReason'] := lQuery.IncompleteReason;
    if lMore then begin
      // A page token is consumed once. Lost-response retries must use the exact
      // request and an idempotency key; reusing an old token cannot skip a page.
      CreateGUID(lId);
      lToken := GUIDToString(lId);
      AMetadata.S['nextCursor'] := lToken;
      AMetadata.S['continuationReason'] := 'page_or_scan_budget';
      Cursors.Add(lToken, lQuery);
      lQuery := nil; // Ownership transfers only after admission succeeds.
    end;
  finally
    Dec(ActiveQueries);
    lQuery.Free;
  end;
end;

finalization
  Cursors.Free;
end.
