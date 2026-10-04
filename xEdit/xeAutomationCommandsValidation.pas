{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsValidation;

interface

const
  xeAutomationCircularDepthLimit = 1024;
  xeAutomationCircularVisitedLimit = 100000;

procedure xeAutomationRegisterValidationCommands;

implementation

uses
  Classes,
  System.Diagnostics,
  System.Generics.Collections,
  SysUtils,
  JsonDataObjects,
  xeAutomationRecordComparison,
  wbInterface,
  wbHelpers,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationJobs,
  xeAutomationObjectModel;

const
  xeAutomationValidationCheckForErrorsKind = 'validation.check_for_errors';
  xeAutomationValidationCheckForItmKind = 'validation.check_for_itm';
  xeAutomationValidationCheckForDeletedRefsKind = 'validation.check_for_deleted_refs';
  xeAutomationValidationCircularListsKind = 'validation.circular_leveled_lists';

function xeAutomationValidationKindName(const AKind: string): string;
begin
  Result := AKind;
end;

procedure xeAutomationValidateValidationStart(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
var
  lFiles: TJsonArray;
  i: Integer;
begin
  if not Assigned(ATarget) then
    raise xeAutomationInvalidRequest('Automation validation target is required');
  if not ATarget.Contains('files') then
    raise xeAutomationInvalidRequest('Automation validation target.files is required');
  if ATarget.Types['files'] <> jdtArray then
    raise xeAutomationInvalidRequest('Automation validation target.files must be an array');

  lFiles := ATarget.A['files'];
  if lFiles.Count = 0 then
    raise xeAutomationInvalidRequest('Automation validation target.files must not be empty');
  for i := 0 to Pred(lFiles.Count) do
    if lFiles.Types[i] <> jdtString then
      raise xeAutomationInvalidRequest('Automation validation target.files entries must be strings');

  // Validation kinds are non-mutating even when legacy clients send dryRun:false.
  // Normalize the stored job snapshot to dryRun=true so the contract is visible.
  ADryRun := True;
end;

procedure xeAutomationWriteValidationTarget(const ATarget: TJsonObject; const AFile: IwbFile;
  const ARecord: IwbMainRecord; const APath: string);
begin
  if Assigned(AFile) then
    ATarget.S['file'] := AFile.FileName;
  if Assigned(ARecord) then begin
    ATarget.S['formId'] := ARecord.LoadOrderFormID.ToString(True);
    ATarget.S['signature'] := ARecord.Signature;
  end;
  ATarget.S['path'] := APath;
end;

procedure xeAutomationAddValidationFinding(const AFindings: TJsonArray; const ASource, ASeverity, ACode,
  AMessage: string; const AFile: IwbFile; const ARecord: IwbMainRecord; const APath: string);
var
  lFinding: TJsonObject;
begin
  lFinding := TJsonObject.Create;
  try
    lFinding.S['severity'] := ASeverity;
    lFinding.S['code'] := ACode;
    lFinding.S['message'] := Copy(AMessage, 1, 4096);
    if Length(AMessage) > 4096 then begin
      lFinding.B['messageTruncated'] := True;
      lFinding.I['originalMessageCharacters'] := Length(AMessage);
    end;
    xeAutomationWriteValidationTarget(lFinding.O['target'], AFile, ARecord, APath);
    lFinding.S['source'] := ASource;
    lFinding.O['action'].S['kind'] := 'none';
    lFinding.O['action'].S['reason'] := 'validation_only';
    xeAutomationAppendJobFinding(AFindings, lFinding);
    lFinding := nil;
  finally
    lFinding.Free;
  end;
end;

function xeAutomationDeletedRefCanBeSafelyUndeleted(const ARecord: IwbMainRecord): Boolean;
var
  lLinksToRecord: IwbMainRecord;
begin
  Result := False;
  if not Assigned(ARecord) then
    Exit;
  if ARecord.Signature = 'NAVM' then
    Exit;
  lLinksToRecord := ARecord.MasterOrSelf.BaseRecord;
  if ARecord.IsInjected or (not Assigned(lLinksToRecord)) then
    Exit;
  if (wbGameMode in [gmFNV]) and (lLinksToRecord.Signature = 'TREE') and lLinksToRecord.Flags.HasLODtree then
    Exit;
  Result := True;
end;

function xeAutomationIsDeletedRefSignature(const ARecord: IwbMainRecord): Boolean;
begin
  Result := Assigned(ARecord) and (
    (ARecord.Signature = 'REFR') or
    (ARecord.Signature = 'PGRE') or
    (ARecord.Signature = 'PMIS') or
    (ARecord.Signature = 'ACHR') or
    (ARecord.Signature = 'ACRE') or
    (ARecord.Signature = 'NAVM') or
    (ARecord.Signature = 'PARW') or
    (ARecord.Signature = 'PBAR') or
    (ARecord.Signature = 'PBEA') or
    (ARecord.Signature = 'PCON') or
    (ARecord.Signature = 'PFLA') or
    (ARecord.Signature = 'PHZD'));
end;

function xeAutomationRecordBelongsToFile(const AFile: IwbFile; const ARecord: IwbMainRecord): Boolean;
begin
  Result := Assigned(AFile) and Assigned(ARecord) and Assigned(ARecord._File) and SameText(ARecord._File.FileName, AFile.FileName);
end;

const
  xeAutomationCircularMessageLimit = 4096;
  xeAutomationCircularPathLimit = 100;

type
  TxeAutomationCircularPhase = (xacScanRoots, xacWalk, xacCycle, xacUnwind, xacDone);

  TxeAutomationCircularFrame = class
  public
    Record_: IwbMainRecord;
    Entries: IwbContainerElementRef;
    RefPath: string;
    Entered: Boolean;
    NextEntry: Integer;
    constructor Create(const ARecord: IwbMainRecord);
  end;

  TxeAutomationCircularStepper = class(TxeAutomationJobStepper)
  private
    FFileName: string;
    FFile: IwbFile;
    FGroup: IwbGroupRecord;
    FRoot: IwbMainRecord;
    FStack: TObjectList<TxeAutomationCircularFrame>;
    // All edges resolve to WinningOverride, so a FormID identifies the native
    // record whose tag the GUI checker would set. No shared tags are modified.
    FVisited: TDictionary<Cardinal, Boolean>;
    FActivePath: TDictionary<Cardinal, Integer>;
    FPhase: TxeAutomationCircularPhase;
    FRow, FPendingFinding: TJsonObject;
    FSignatureIndex, FRootIndex, FChecked, FCycles, FTraversedEntries: Integer;
    FSteps, FLastWorkUnits, FFindingsBefore: Integer;
    FCycleNext, FMessageCharacters: Integer;
    FComplete: Boolean;
    procedure PopFrame;
    procedure StartCycle(const AStart: Integer);
    procedure AdvanceOne(const AFindings: TJsonArray);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    function Advance(const AFindings: TJsonArray;
      const ASummary, AResult, AFailure: TJsonObject): Boolean; override;
    procedure WriteProgress(const AProgress: TJsonObject); override;
  end;

constructor TxeAutomationCircularFrame.Create(const ARecord: IwbMainRecord);
begin
  inherited Create;
  Record_ := ARecord;
end;

constructor TxeAutomationCircularStepper.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FStack := TObjectList<TxeAutomationCircularFrame>.Create(True);
  FVisited := TDictionary<Cardinal, Boolean>.Create;
  FActivePath := TDictionary<Cardinal, Integer>.Create;
end;

destructor TxeAutomationCircularStepper.Destroy;
begin
  FPendingFinding.Free;
  FActivePath.Free;
  FVisited.Free;
  FStack.Free;
  FRoot := nil;
  FGroup := nil;
  FFile := nil;
  inherited;
end;

procedure TxeAutomationCircularStepper.PopFrame;
begin
  if FStack.Last.Entered then
    FActivePath.Remove(FStack.Last.Record_.LoadOrderFormID.ToCardinal);
  FStack.Delete(FStack.Count - 1);
end;

procedure TxeAutomationCircularStepper.StartCycle(const AStart: Integer);
const
  Prefix = 'Circular Leveled List found: ';
begin
  FPendingFinding := TJsonObject.Create;
  FPendingFinding.S['source'] := xeAutomationValidationCircularListsKind;
  FPendingFinding.S['severity'] := 'error';
  FPendingFinding.S['code'] := 'circular_leveled_list';
  FPendingFinding.S['message'] := Prefix;
  FMessageCharacters := Length(Prefix);
  // As in the GUI handler, target is the checked root's winning override, even
  // when the actual cycle starts deeper in that root's dependency graph.
  xeAutomationWriteValidationTarget(FPendingFinding.O['target'], FRoot._File, FRoot, '');
  FPendingFinding.O['target'].S['formId'] := FRoot.LoadOrderFormID.ToString(False);
  FPendingFinding.O['action'].S['kind'] := 'none';
  FPendingFinding.O['action'].S['reason'] := 'validation_only';
  FPendingFinding.A['cyclePathNames'].Clear;
  FPendingFinding.A['cyclePath'].Clear;
  FCycleNext := AStart;
  FPhase := xacCycle;
end;

procedure TxeAutomationCircularStepper.AdvanceOne(const AFindings: TJsonArray);
const
  Signatures: array[0..3] of string = ('LVLI', 'LVLC', 'LVLN', 'LVSP');
var
  lFrame: TxeAutomationCircularFrame;
  lRecord, lTarget: IwbMainRecord;
  lFormId: Cardinal;
  lCycleStart: Integer;
  lName, lPart: string;
  lPathItem: TJsonObject;
begin
  case FPhase of
    xacScanRoots: begin
      if FSignatureIndex > High(Signatures) then begin
        FPhase := xacDone;
        Exit;
      end;
      if not Assigned(FGroup) then begin
        FGroup := FFile.GroupBySignature[Signatures[FSignatureIndex]];
        if not Assigned(FGroup) then Inc(FSignatureIndex);
        Exit;
      end;
      if FRootIndex >= FGroup.ElementCount then begin
        FGroup := nil;
        FRootIndex := 0;
        Inc(FSignatureIndex);
        Exit;
      end;
      if Supports(FGroup.Elements[FRootIndex], IwbMainRecord, lRecord) then begin
        FRoot := lRecord.WinningOverride;
        if Assigned(FRoot) then begin
          Inc(FChecked);
          FStack.Add(TxeAutomationCircularFrame.Create(FRoot));
          FPhase := xacWalk;
        end;
      end;
      Inc(FRootIndex);
    end;
    xacWalk: begin
      if FStack.Count = 0 then begin
        FRoot := nil;
        FPhase := xacScanRoots;
        Exit;
      end;
      lFrame := FStack.Last;
      lFormId := lFrame.Record_.LoadOrderFormID.ToCardinal;
      if not lFrame.Entered then begin
        // Native checker compares the active path BEFORE its tagged/visited
        // test. Reversing these tests would silently miss every back-edge.
        if FActivePath.TryGetValue(lFormId, lCycleStart) then begin
          StartCycle(lCycleStart);
          Exit;
        end;
        if FVisited.ContainsKey(lFormId) then begin
          PopFrame;
          Exit;
        end;
        if FVisited.Count >= xeAutomationCircularVisitedLimit then
          raise xeAutomationNewError('job_capacity', 'Circular validation exceeds the retained visited-record budget');
        FVisited.Add(lFormId, True);
        FActivePath.Add(lFormId, FStack.Count - 1);
        lFrame.Entered := True;
        lFrame.RefPath := wbLeveledListEntryReferencePath(lFrame.Record_.Signature);
        wbLeveledListEntries(lFrame.Record_, lFrame.Entries);
      end else if Assigned(lFrame.Entries) and (lFrame.NextEntry < lFrame.Entries.ElementCount) then begin
        Inc(FTraversedEntries);
        if wbLeveledListEntryTarget(lFrame.Record_, lFrame.Entries, lFrame.NextEntry, lFrame.RefPath, lTarget) then begin
          if not Assigned(lTarget) then
            raise xeAutomationNewError(xeAutomationErrorInternalError, 'A linked leveled list has no winning override');
          if FStack.Count >= xeAutomationCircularDepthLimit then
            raise xeAutomationNewError('job_capacity', 'Circular validation exceeds the retained graph-depth budget');
          FStack.Add(TxeAutomationCircularFrame.Create(lTarget));
        end;
        Inc(lFrame.NextEntry);
      end else
        PopFrame;
    end;
    xacCycle: begin
      // Diagnostic construction also yields: one name/locator per work unit.
      // The repeated closing record is included, matching the native message.
      if FCycleNext < FStack.Count then begin
        lRecord := FStack[FCycleNext].Record_;
        lName := lRecord.Name;
        lPart := '';
        if FPendingFinding.I['cyclePathLength'] > 0 then lPart := ' -> ';
        Inc(FMessageCharacters, Length(lPart) + Length(lName));
        if Length(FPendingFinding.S['message']) < xeAutomationCircularMessageLimit then
          FPendingFinding.S['message'] := FPendingFinding.S['message'] +
            Copy(lPart + lName, 1, xeAutomationCircularMessageLimit - Length(FPendingFinding.S['message']));
        if FMessageCharacters > xeAutomationCircularMessageLimit then begin
          FPendingFinding.B['messageTruncated'] := True;
          FPendingFinding.I['originalMessageCharacters'] := FMessageCharacters;
        end;
        if FPendingFinding.A['cyclePathNames'].Count < xeAutomationCircularPathLimit then begin
          FPendingFinding.A['cyclePathNames'].Add(Copy(lName, 1, 160));
          if Length(lName) > 160 then FPendingFinding.B['cyclePathTruncated'] := True;
          lPathItem := FPendingFinding.A['cyclePath'].AddObject;
          xeAutomationWriteValidationTarget(lPathItem, lRecord._File, lRecord, '');
          lPathItem.S['formId'] := lRecord.LoadOrderFormID.ToString(False);
        end else
          FPendingFinding.B['cyclePathTruncated'] := True;
        FPendingFinding.I['cyclePathLength'] := FPendingFinding.I['cyclePathLength'] + 1;
        Inc(FCycleNext);
      end else begin
        xeAutomationAppendJobFinding(AFindings, FPendingFinding);
        FPendingFinding := nil;
        Inc(FCycles);
        // A native cycle exception aborts this root, retaining its visited tags.
        // Keep the same behavior but unwind one frame at a time.
        FPhase := xacUnwind;
      end;
    end;
    xacUnwind: begin
      if FStack.Count > 0 then PopFrame
      else begin
        FRoot := nil;
        FPhase := xacScanRoots;
      end;
    end;
    xacDone: FComplete := True;
  end;
end;

function TxeAutomationCircularStepper.Advance(const AFindings: TJsonArray;
  const ASummary, AResult, AFailure: TJsonObject): Boolean;
var
  lTimer: TStopwatch;
  lCheckedBefore, lCyclesBefore: Integer;
begin
  Result := FComplete;
  if FComplete then Exit;
  lTimer := TStopwatch.StartNew;
  Inc(FSteps);
  FLastWorkUnits := 0;
  lCheckedBefore := FChecked;
  lCyclesBefore := FCycles;
  try
    if not Assigned(FFile) then begin
      if wbGameMode = gmTES3 then
        raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
          'Circular leveled-list checking requires a plugin game with GRUP records');
      FFile := xeAutomationRequirePluginFile(FFileName);
      FFindingsBefore := AFindings.Count;
      FRow := AResult.A['files'].AddObject;
      FRow.S['fileName'] := FFile.FileName;
      FRow.B['dirtyBefore'] := FFile.Modified;
      FRow.B['complete'] := False;
      ASummary.S['kind'] := xeAutomationValidationCircularListsKind;
      ASummary.B['validationOnly'] := True;
      if not ASummary.Contains('fileCount') then ASummary.I['fileCount'] := 0;
      Inc(FLastWorkUnits);
    end;
    while not FComplete and (FLastWorkUnits < xeAutomationJobStepWorkLimit) and
          (lTimer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
      Inc(FLastWorkUnits);
      AdvanceOne(AFindings);
    end;
    if FComplete then ASummary.I['fileCount'] := ASummary.I['fileCount'] + 1;
    Result := FComplete;
  finally
    ASummary.I['checkedRecords'] := ASummary.I['checkedRecords'] + FChecked - lCheckedBefore;
    ASummary.I['cycleCount'] := ASummary.I['cycleCount'] + FCycles - lCyclesBefore;
    ASummary.I['findingCount'] := AFindings.Count;
    if Assigned(FRow) then begin
      FRow.B['complete'] := FComplete;
      FRow.I['checkedRecords'] := FChecked;
      FRow.I['cycleCount'] := FCycles;
      FRow.I['visitedRecords'] := FVisited.Count;
      FRow.I['traversedEntries'] := FTraversedEntries;
      FRow.I['findingCount'] := AFindings.Count - FFindingsBefore;
      FRow.B['dirtyAfter'] := FFile.Modified;
      FRow.B['dirtyChanged'] := FRow.B['dirtyBefore'] <> FFile.Modified;
      ASummary.B['dirtyChanged'] := ASummary.B['dirtyChanged'] or FRow.B['dirtyChanged'];
    end;
  end;
end;

procedure TxeAutomationCircularStepper.WriteProgress(const AProgress: TJsonObject);
const
  PhaseNames: array[TxeAutomationCircularPhase] of string = ('roots', 'graph', 'cycle-report', 'unwind', 'complete');
begin
  AProgress.S['fileName'] := FFileName;
  AProgress.B['fileComplete'] := FComplete;
  AProgress.S['phase'] := PhaseNames[FPhase];
  AProgress.I['checkedRecords'] := FChecked;
  AProgress.I['cycleCount'] := FCycles;
  AProgress.I['visitedElements'] := FVisited.Count;
  AProgress.I['traversedEntries'] := FTraversedEntries;
  AProgress.I['retainedDepth'] := FStack.Count;
  AProgress.I['depthLimit'] := xeAutomationCircularDepthLimit;
  AProgress.I['visitedLimit'] := xeAutomationCircularVisitedLimit;
  AProgress.I['steps'] := FSteps;
  AProgress.I['lastWorkUnits'] := FLastWorkUnits;
  AProgress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  AProgress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  AProgress.B['nativeCallsPreemptible'] := False;
  AProgress.B['usesSharedNativeTags'] := False;
  if Assigned(FRoot) then
    xeAutomationWriteValidationTarget(AProgress.O['root'], FRoot._File, FRoot, '');
end;

function xeAutomationCreateCircularStepper(const AKind: string;
  const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject): TxeAutomationJobStepper;
begin
  Result := TxeAutomationCircularStepper.Create(Trim(ATarget.A['files'].S[0]));
end;

procedure xeAutomationCircularListsJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
var
  lStepper: TxeAutomationJobStepper;
  i: Integer;
begin
  // Compatibility handler shares the cursor implementation; jobs attach the
  // factory and advance it once per poll instead of draining it here.
  for i := 0 to Pred(ATarget.A['files'].Count) do begin
    lStepper := TxeAutomationCircularStepper.Create(ATarget.A['files'].S[i]);
    try
      while not lStepper.Advance(AFindings, ASummary, AResult, AFailure) do begin end;
    finally
      lStepper.Free;
    end;
  end;
end;

type
  TxeAutomationValidationFrame = class
  public
    Element: IwbElement;
    Container: IwbContainerElementRef;
    Entered: Boolean;
    NextChild: Integer;
    constructor Create(const AElement: IwbElement);
  end;

  TxeAutomationValidationStepper = class(TxeAutomationJobStepper)
  private
    FKind, FFileName: string;
    FFile: IwbFile;
    FStack: TObjectList<TxeAutomationValidationFrame>;
    FRow: TJsonObject; // Owned by the durable job result, never by this cursor.
    FCheckedRecords, FVisitedElements, FFindingsBefore: Integer;
    FSteps, FLastWorkUnits: Integer;
    FComplete: Boolean;
    procedure CheckElement(const AElement: IwbElement; const AFindings: TJsonArray);
    procedure AddNoFindings(const AFindings: TJsonArray);
  public
    constructor Create(const AKind, AFileName: string);
    destructor Destroy; override;
    function Advance(const AFindings: TJsonArray;
      const ASummary, AResult, AFailure: TJsonObject): Boolean; override;
    procedure WriteProgress(const AProgress: TJsonObject); override;
  end;

constructor TxeAutomationValidationFrame.Create(const AElement: IwbElement);
begin
  inherited Create;
  Element := AElement;
end;

constructor TxeAutomationValidationStepper.Create(const AKind, AFileName: string);
begin
  inherited Create;
  FKind := AKind;
  FFileName := AFileName;
  FStack := TObjectList<TxeAutomationValidationFrame>.Create(True);
end;

destructor TxeAutomationValidationStepper.Destroy;
begin
  // Release every pinned interface on success, cancellation and failure.
  FStack.Free;
  FFile := nil;
  inherited;
end;

procedure TxeAutomationValidationStepper.CheckElement(const AElement: IwbElement;
  const AFindings: TJsonArray);
var
  lError, lCode, lSeverity, lMessage: string;
  lRecord: IwbMainRecord;
begin
  if FKind = xeAutomationValidationCheckForErrorsKind then begin
    // The native check is indivisible and may itself initialize/traverse data.
    lError := AElement.Check;
    if lError <> '' then begin
      lRecord := AElement.ContainingMainRecord;
      xeAutomationAddValidationFinding(AFindings, FKind, 'error', xeAutomationFindingValidationCheckError,
        lError, FFile, lRecord, AElement.Path);
    end;
    if AElement.ElementType = etMainRecord then Inc(FCheckedRecords);
  end else if Supports(AElement, IwbMainRecord, lRecord) and
              xeAutomationRecordBelongsToFile(FFile, lRecord) then begin
    Inc(FCheckedRecords);
    if FKind = xeAutomationValidationCheckForItmKind then begin
      if xeAutomationRecordIsIdenticalToMaster(lRecord) then
        xeAutomationAddValidationFinding(AFindings, FKind, 'warning', xeAutomationFindingValidationItmRecord,
          Format('Identical to master record: %s', [lRecord.Name]), FFile, lRecord, '');
    end else if lRecord.IsEditable and lRecord.IsDeleted and xeAutomationIsDeletedRefSignature(lRecord) then begin
      lCode := xeAutomationFindingValidationDeletedReference;
      lSeverity := 'warning';
      lMessage := Format('Deleted reference: %s', [lRecord.Name]);
      if lRecord.Signature = 'NAVM' then begin
        lCode := xeAutomationFindingValidationDeletedNavmesh;
        lSeverity := 'error';
        lMessage := Format('Deleted NavMesh cannot be safely undeleted by xEdit cleaning: %s', [lRecord.Name]);
      end else if not xeAutomationDeletedRefCanBeSafelyUndeleted(lRecord) then begin
        lCode := xeAutomationFindingValidationDeletedReferenceSkipped;
        lSeverity := 'info';
        lMessage := Format('Deleted reference cannot be safely undeleted by xEdit cleaning: %s', [lRecord.Name]);
      end;
      xeAutomationAddValidationFinding(AFindings, FKind, lSeverity, lCode, lMessage, FFile, lRecord, '');
    end;
  end;
end;

procedure TxeAutomationValidationStepper.AddNoFindings(const AFindings: TJsonArray);
var
  lCode, lMessage: string;
begin
  if FKind = xeAutomationValidationCheckForErrorsKind then begin
    lCode := xeAutomationFindingValidationNoErrorsFound;
    lMessage := Format('No xEdit check errors found in %s', [FFileName]);
  end else if FKind = xeAutomationValidationCheckForItmKind then begin
    lCode := xeAutomationFindingValidationNoItmRecordsFound;
    lMessage := Format('No identical-to-master records found in %s', [FFileName]);
  end else begin
    lCode := xeAutomationFindingValidationNoDeletedRefsFound;
    lMessage := Format('No deleted references found in %s', [FFileName]);
  end;
  xeAutomationAddValidationFinding(AFindings, FKind, 'info', lCode, lMessage, FFile, nil, '');
end;

function TxeAutomationValidationStepper.Advance(const AFindings: TJsonArray;
  const ASummary, AResult, AFailure: TJsonObject): Boolean;
var
  lFrame: TxeAutomationValidationFrame;
  lChild: IwbElement;
  lTimer: TStopwatch;
  lCheckedBefore, lVisitedBefore: Integer;
begin
  Result := FComplete;
  if FComplete then Exit;
  lTimer := TStopwatch.StartNew;
  Inc(FSteps);
  FLastWorkUnits := 0;
  lCheckedBefore := FCheckedRecords;
  lVisitedBefore := FVisitedElements;
  try
    if not Assigned(FFile) then begin
      FFile := xeAutomationRequirePluginFile(FFileName);
      FFindingsBefore := AFindings.Count;
      FRow := AResult.A['files'].AddObject;
      FRow.S['fileName'] := FFile.FileName;
      FRow.B['dirtyBefore'] := FFile.Modified;
      FRow.B['complete'] := False;
      ASummary.S['kind'] := FKind;
      ASummary.B['validationOnly'] := True;
      if not ASummary.Contains('fileCount') then ASummary.I['fileCount'] := 0;
      FStack.Add(TxeAutomationValidationFrame.Create(FFile));
      Inc(FLastWorkUnits);
    end;
    // Each enter, child fetch and pop consumes a unit. No eager child array,
    // recursive call or restart/rescan of an already visited subtree.
    while (FStack.Count > 0) and (FLastWorkUnits < xeAutomationJobStepWorkLimit) and
          (lTimer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
      lFrame := FStack.Last;
      Inc(FLastWorkUnits);
      if not lFrame.Entered then begin
        lFrame.Entered := True;
        Inc(FVisitedElements);
        CheckElement(lFrame.Element, AFindings);
        Supports(lFrame.Element, IwbContainerElementRef, lFrame.Container);
      end else if Assigned(lFrame.Container) and
                  (lFrame.NextChild < lFrame.Container.ElementCount) then begin
        if FStack.Count >= xeAutomationJobStepDepthLimit then
          raise xeAutomationNewError('job_capacity', 'Validation traversal exceeds the retained depth budget');
        lChild := lFrame.Container.Elements[lFrame.NextChild];
        Inc(lFrame.NextChild);
        if Assigned(lChild) then FStack.Add(TxeAutomationValidationFrame.Create(lChild));
        lChild := nil;
      end else
        FStack.Delete(FStack.Count - 1);
    end;
    if FStack.Count = 0 then begin
      // Never emit a clean-file finding for an incomplete/canceled traversal.
      if AFindings.Count = FFindingsBefore then AddNoFindings(AFindings);
      FComplete := True;
      ASummary.I['fileCount'] := ASummary.I['fileCount'] + 1;
    end;
    Result := FComplete;
  finally
    ASummary.I['checkedRecords'] := ASummary.I['checkedRecords'] + FCheckedRecords - lCheckedBefore;
    ASummary.I['visitedElements'] := ASummary.I['visitedElements'] + FVisitedElements - lVisitedBefore;
    ASummary.I['findingCount'] := AFindings.Count;
    if Assigned(FRow) then begin
      FRow.B['complete'] := FComplete;
      FRow.I['checkedRecords'] := FCheckedRecords;
      FRow.I['visitedElements'] := FVisitedElements;
      FRow.I['findingCount'] := AFindings.Count - FFindingsBefore;
      FRow.B['dirtyAfter'] := FFile.Modified;
      FRow.B['dirtyChanged'] := FRow.B['dirtyBefore'] <> FFile.Modified;
      ASummary.B['dirtyChanged'] := ASummary.B['dirtyChanged'] or FRow.B['dirtyChanged'];
    end;
  end;
end;

procedure TxeAutomationValidationStepper.WriteProgress(const AProgress: TJsonObject);
begin
  AProgress.S['fileName'] := FFileName;
  AProgress.B['fileComplete'] := FComplete;
  AProgress.I['checkedRecords'] := FCheckedRecords;
  AProgress.I['visitedElements'] := FVisitedElements;
  AProgress.I['retainedDepth'] := FStack.Count;
  AProgress.I['steps'] := FSteps;
  AProgress.I['lastWorkUnits'] := FLastWorkUnits;
  AProgress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  AProgress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  AProgress.B['nativeCallsPreemptible'] := False;
end;

function xeAutomationCreateValidationStepper(const AKind: string;
  const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject): TxeAutomationJobStepper;
begin
  // The factory's target is temporary; retain only the selected file name.
  Result := TxeAutomationValidationStepper.Create(AKind, Trim(ATarget.A['files'].S[0]));
end;

procedure xeAutomationRunValidationJob(const AKind: string; const ATarget: TJsonObject;
  const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
var
  lStepper: TxeAutomationJobStepper;
  i: Integer;
begin
  // Compatibility handler uses the same semantics; registered automation jobs
  // attach the factory below and never drain a file synchronously here.
  for i := 0 to Pred(ATarget.A['files'].Count) do begin
    lStepper := TxeAutomationValidationStepper.Create(AKind, ATarget.A['files'].S[i]);
    try
      while not lStepper.Advance(AFindings, ASummary, AResult, AFailure) do begin end;
    finally
      lStepper.Free;
    end;
  end;
end;

procedure xeAutomationValidationJobHandler(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
begin
  xeAutomationRunValidationJob(xeAutomationValidationKindName(AOptions.S['kind']), ATarget, AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationCheckForErrorsJobHandler(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
begin
  xeAutomationRunValidationJob(xeAutomationValidationCheckForErrorsKind, ATarget, AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationCheckForItmJobHandler(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
begin
  xeAutomationRunValidationJob(xeAutomationValidationCheckForItmKind, ATarget, AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationCheckForDeletedRefsJobHandler(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
begin
  xeAutomationRunValidationJob(xeAutomationValidationCheckForDeletedRefsKind, ATarget, AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationRegisterValidationCommands;
begin
  xeAutomationRegisterJobKindWithValidator(xeAutomationValidationCheckForErrorsKind, xeAutomationCheckForErrorsJobHandler,
    xeAutomationValidateValidationStart);
  xeAutomationRegisterJobKindWithValidator(xeAutomationValidationCheckForItmKind, xeAutomationCheckForItmJobHandler,
    xeAutomationValidateValidationStart);
  xeAutomationRegisterJobKindWithValidator(xeAutomationValidationCheckForDeletedRefsKind, xeAutomationCheckForDeletedRefsJobHandler,
    xeAutomationValidateValidationStart);
  xeAutomationRegisterJobStepper(xeAutomationValidationCheckForErrorsKind, xeAutomationCreateValidationStepper);
  xeAutomationRegisterJobStepper(xeAutomationValidationCheckForItmKind, xeAutomationCreateValidationStepper);
  xeAutomationRegisterJobStepper(xeAutomationValidationCheckForDeletedRefsKind, xeAutomationCreateValidationStepper);
  xeAutomationRegisterJobKindWithValidator(xeAutomationValidationCircularListsKind, xeAutomationCircularListsJob,
    xeAutomationValidateValidationStart);
  xeAutomationRegisterJobStepper(xeAutomationValidationCircularListsKind, xeAutomationCreateCircularStepper);
end;

end.
