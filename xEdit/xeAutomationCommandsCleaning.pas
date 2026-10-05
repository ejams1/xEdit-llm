{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsCleaning;

interface

procedure xeAutomationRegisterCleaningCommands;

implementation

uses
  SysUtils,
  System.Diagnostics,
  Generics.Collections,
  JsonDataObjects,
  wbInterface,
  wbImplementation,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationJobs,
  xeAutomationMutationPolicy,
  xeAutomationMutationAudit,
  xeAutomationRecordComparison,
  xeAutomationCommandsSelectiveCleaning,
  xeMainForm;

const
  xeAutomationCleaningQuickCleanKind = 'cleaning.quick_clean';
  xeAutomationCleaningQuickAutoCleanKind = 'cleaning.quick_auto_clean';
  xeAutomationCleaningSortAndCleanMastersKind = 'cleaning.sort_and_clean_masters';

procedure xeAutomationValidateCleaningStart(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
var
  lFiles: TJsonArray;
  i: Integer;
begin
  if not Assigned(ATarget) then
    raise xeAutomationInvalidRequest('Automation cleaning target is required');
  if not ATarget.Contains('files') then
    raise xeAutomationInvalidRequest('Automation cleaning target.files is required');
  if ATarget.Types['files'] <> jdtArray then
    raise xeAutomationInvalidRequest('Automation cleaning target.files must be an array');

  lFiles := ATarget.A['files'];
  if lFiles.Count = 0 then
    raise xeAutomationInvalidRequest('Automation cleaning target.files must not be empty');
  for i := 0 to Pred(lFiles.Count) do
    if lFiles.Types[i] <> jdtString then
      raise xeAutomationInvalidRequest('Automation cleaning target.files entries must be strings');

  // Cleaning is destructive in apply mode, so omitted dryRun must normalize to a
  // planning job at start-time before any active-job or execution state exists.
  if not ADryRunSpecified then
    ADryRun := True;
end;

procedure xeAutomationAddCleaningFinding(const AFindings: TJsonArray; const ASource, ASeverity, ACode, AMessage,
  AFileName, AActionKind, AReason: string; const APlanned, AApplied, ASkipped: Integer);
var
  lFinding: TJsonObject;
begin
  lFinding := TJsonObject.Create;
  try
    lFinding.S['severity'] := ASeverity;
    lFinding.S['code'] := ACode;
    lFinding.S['message'] := AMessage;
    lFinding.S['source'] := ASource;
    lFinding.O['target'].S['file'] := AFileName;
    lFinding.O['action'].S['kind'] := AActionKind;
    if AReason <> '' then
      lFinding.O['action'].S['reason'] := AReason;
    lFinding.O['counts'].I['planned'] := APlanned;
    lFinding.O['counts'].I['applied'] := AApplied;
    lFinding.O['counts'].I['skipped'] := ASkipped;
    xeAutomationAppendJobFinding(AFindings, lFinding);
    lFinding := nil;
  finally
    lFinding.Free;
  end;
end;

procedure xeAutomationAddDirtyFile(const ATarget: TJsonArray; const AFile: IwbFile);
var
  i: Integer;
begin
  if (not Assigned(AFile)) or (not AFile.Modified) then
    Exit;
  for i := 0 to Pred(ATarget.Count) do
    if SameText(ATarget.S[i], AFile.FileName) then
      Exit;
  ATarget.Add(AFile.FileName);
end;

type
  TCombinedPhase = (cpSort, cpCleanMasters, cpScanMasters, cpApplyCleanMasters, cpMasterReport, cpBeginItm,
    cpCollectItm, cpItm, cpItmReport, cpBeginUdr, cpCollectUdr, cpUdr, cpUdrReport, cpComplete);
  TCombinedFrame = class
  public
    Element: IwbElement;
    Container: IwbContainerElementRef;
    Entered: Boolean;
    NextChild: Integer;
    constructor Create(const element: IwbElement);
  end;
  TCombinedStepper = class(TxeAutomationJobStepper)
  private
    FKind, FFileName: string;
    FDryRun: Boolean;
    FFile: IwbFile;
    FPhase: TCombinedPhase;
    FMasterScan: TwbAutomationMasterUseScan;
    FMasterCountBefore, FMasterScanWork, FMasterNativeUnits, FMasterDepth: Integer;
    FStack: TObjectList<TCombinedFrame>;
    FRecords: TQueue<IwbMainRecord>;
    FRow, FLastLocator: TJsonObject;
    FStageSnapshot: TxeAutomationMutationSnapshot;
    FPlanned, FApplied, FSkipped, FDeletedNavmesh: Integer;
    FVisited, FCollected, FProcessed, FSteps, FLastWork, FLastMutations: Integer;
    FComplete: Boolean;
    procedure BeginOperation(const operation: string; const resultData: TJsonObject);
    procedure BeginCollection(const phase: TCombinedPhase);
    procedure CollectOne(const nextPhase: TCombinedPhase);
    procedure SetLastRecord(const recordRef: IwbMainRecord);
    procedure RecordOne(const itm: Boolean);
    procedure BeginMasterScan;
    procedure ScanMasterOne;
    procedure MasterOne(const sort: Boolean);
    procedure PublishOperation(const findings: TJsonArray);
    procedure CheckUdrSettings;
  public
    constructor Create(const kind, fileName: string; const dry: Boolean);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TCombinedFrame.Create(const element: IwbElement);
begin
  inherited Create;
  Element := element;
end;

constructor TCombinedStepper.Create(const kind, fileName: string; const dry: Boolean);
begin
  inherited Create;
  FKind := kind;
  FFileName := fileName;
  FDryRun := dry;
  FStack := TObjectList<TCombinedFrame>.Create(True);
  FRecords := TQueue<IwbMainRecord>.Create;
  FLastLocator := TJsonObject.Create;
end;

destructor TCombinedStepper.Destroy;
begin
  FMasterScan.Free;
  FLastLocator.Free;
  FRecords.Free;
  FStack.Free;
  FStageSnapshot.Files := nil;
  FFile := nil;
  inherited;
end;

procedure TCombinedStepper.BeginOperation(const operation: string; const resultData: TJsonObject);
begin
  FStageSnapshot := xeAutomationCaptureMutationSnapshot;
  FRow := resultData.A['files'].AddObject;
  FRow.S['fileName'] := FFile.FileName;
  FRow.S['operation'] := operation;
  FRow.B['dirtyBefore'] := FFile.Modified;
  FRow.B['complete'] := False;
  FRow.B['workComplete'] := False;
  FRow.I['planned'] := 0;
  FRow.I['applied'] := 0;
  FRow.I['skipped'] := 0;
  FDeletedNavmesh := 0;
  FVisited := 0; FCollected := 0; FProcessed := 0;
  FLastLocator.Clear;
  if operation = 'sort_and_clean_masters' then begin
    FRow.O['operations'].O['sort'].S['outcome'] := 'not_started';
    FRow.O['operations'].O['cleanMasters'].S['outcome'] := 'not_started';
    FRow.O['operations'].O['sort'].I['planned'] := 0;
    FRow.O['operations'].O['sort'].I['applied'] := 0;
    FRow.O['operations'].O['sort'].I['skipped'] := 0;
    FRow.O['operations'].O['sort'].B['complete'] := False;
    FRow.O['operations'].O['cleanMasters'].I['planned'] := 0;
    FRow.O['operations'].O['cleanMasters'].I['applied'] := 0;
    FRow.O['operations'].O['cleanMasters'].I['skipped'] := 0;
    FRow.O['operations'].O['cleanMasters'].B['complete'] := False;
  end;
  if operation = 'undelete_and_disable_refs' then
    with FRow.O['nativeSettings'] do begin
      B['setZ'] := wbUDRSetZ; F['z'] := wbUDRSetZValue;
      B['setXESP'] := wbUDRSetXESP;
      B['setScale'] := wbUDRSetScale; F['scale'] := wbUDRSetScaleValue;
      B['setMSTT'] := wbUDRSetMSTT; S['msttFormId'] := IntToHex(wbUDRSetMSTTValue, 8);
    end;
end;

procedure TCombinedStepper.BeginCollection(const phase: TCombinedPhase);
begin
  // The queue is empty after the preceding stage, so no retained root is
  // revisited or cleared in bulk here. Ownership transfers to Dequeue later.
  FVisited := 0; FCollected := 0; FProcessed := 0;
  FStack.Add(TCombinedFrame.Create(FFile));
  FPhase := phase;
end;

procedure TCombinedStepper.SetLastRecord(const recordRef: IwbMainRecord);
begin
  FLastLocator.Clear;
  FLastLocator.S['file'] := FFile.FileName;
  FLastLocator.S['formId'] := recordRef.LoadOrderFormID.ToString(False);
  FLastLocator.S['path'] := '';
end;

procedure TCombinedStepper.CollectOne(const nextPhase: TCombinedPhase);
var
  frame: TCombinedFrame;
  recordRef: IwbMainRecord;
  child: IwbElement;
begin
  if FStack.Count = 0 then begin
    FPhase := nextPhase;
    Exit;
  end;
  frame := FStack.Last;
  if not frame.Entered then begin
    frame.Entered := True;
    Inc(FVisited);
    if Supports(frame.Element, IwbMainRecord, recordRef) and Assigned(recordRef._File) and
       SameText(recordRef._File.FileName, FFile.FileName) then begin
      SetLastRecord(recordRef);
      FRecords.Enqueue(recordRef);
      Inc(FCollected);
    end;
    Supports(frame.Element, IwbContainerElementRef, frame.Container);
  end else if Assigned(frame.Container) and (frame.NextChild < frame.Container.ElementCount) then begin
    child := frame.Container.Elements[frame.NextChild];
    Inc(frame.NextChild);
    if Assigned(child) then FStack.Add(TCombinedFrame.Create(child));
  end else
    FStack.Delete(FStack.Count - 1);
end;

procedure TCombinedStepper.CheckUdrSettings;
begin
  with FRow.O['nativeSettings'] do
    if (B['setZ'] <> wbUDRSetZ) or (F['z'] <> wbUDRSetZValue) or
       (B['setXESP'] <> wbUDRSetXESP) or (B['setScale'] <> wbUDRSetScale) or
       (F['scale'] <> wbUDRSetScaleValue) or (B['setMSTT'] <> wbUDRSetMSTT) or
       (S['msttFormId'] <> IntToHex(wbUDRSetMSTTValue, 8)) then
      raise xeAutomationNewError('job_state_changed', 'Native UDR settings changed between cleaning steps; restart the job');
end;

procedure TCombinedStepper.RecordOne(const itm: Boolean);
var
  recordRef: IwbMainRecord;
  navmesh: Boolean;
begin
  if FRecords.Count = 0 then begin
    FRow.B['workComplete'] := True;
    if itm then FPhase := cpItmReport else FPhase := cpUdrReport;
    Exit;
  end;
  recordRef := FRecords.Dequeue;
  Inc(FProcessed);
  SetLastRecord(recordRef); // Copy identity before Remove can detach this root.
  if itm then begin
    if not xeAutomationRecordIsIdenticalToMaster(recordRef) then Exit;
    if xeAutomationIdenticalRecordRemovalReason(recordRef) <> '' then begin
      Inc(FSkipped); FRow.I['skipped'] := FRow.I['skipped'] + 1; Exit;
    end;
  end else begin
    if not xeAutomationRecordIsDeletedRefCandidate(recordRef) then Exit;
    if not xeAutomationDeletedRefCanBeCleaned(recordRef, navmesh) then begin
      Inc(FSkipped); FRow.I['skipped'] := FRow.I['skipped'] + 1;
      if navmesh then Inc(FDeletedNavmesh);
      Exit;
    end;
    if not recordRef.IsEditable then begin
      Inc(FSkipped); FRow.I['skipped'] := FRow.I['skipped'] + 1; Exit;
    end;
  end;
  Inc(FPlanned); FRow.I['planned'] := FRow.I['planned'] + 1;
  if not FDryRun then begin
    xeAutomationRequireWritableCleaningTarget(FFile);
    if not itm then CheckUdrSettings;
    Inc(FLastMutations);
    if itm then recordRef.Remove else xeAutomationUndeleteAndDisableRefInMemory(recordRef);
    Inc(FApplied); FRow.I['applied'] := FRow.I['applied'] + 1;
  end;
end;

procedure TCombinedStepper.BeginMasterScan;
var operation: TJsonObject;
begin
  xeAutomationRequireWritableCleaningTarget(FFile);
  operation := FRow.O['operations'].O['cleanMasters'];
  operation.S['outcome'] := 'scanning';
  operation.I['planned'] := 1;
  Inc(FPlanned); FRow.I['planned'] := FRow.I['planned'] + 1;
  FMasterCountBefore := FFile.MasterCount[True];
  FMasterScan := wbAutomationMasterUseScan(FFile);
  FPhase := cpScanMasters;
end;

procedure TCombinedStepper.ScanMasterOne;
var complete: Boolean;
begin
  try
    complete := FMasterScan.Advance;
  finally
    FMasterScanWork := FMasterScan.WorkUnits;
    FMasterNativeUnits := FMasterScan.NativeUnits;
    FMasterDepth := FMasterScan.RetainedDepth;
    with FRow.O['operations'].O['cleanMasters'] do begin
      I['scanWorkUnits'] := FMasterScanWork;
      I['nativeUsageCalls'] := FMasterNativeUnits;
    end;
  end;
  if complete then begin
    FRow.O['operations'].O['cleanMasters'].B['scanComplete'] := True;
    FPhase := cpApplyCleanMasters;
  end;
end;

procedure TCombinedStepper.MasterOne(const sort: Boolean);
var
  operation: TJsonObject;
  planned, applied, skipped: Integer;
begin
  if sort then operation := FRow.O['operations'].O['sort']
  else operation := FRow.O['operations'].O['cleanMasters'];
  operation.S['outcome'] := 'attempted';
  if operation.I['planned'] = 0 then begin
    operation.I['planned'] := 1;
    Inc(FPlanned); FRow.I['planned'] := FRow.I['planned'] + 1;
  end;
  if not FDryRun then begin
    xeAutomationRequireWritableCleaningTarget(FFile);
    Inc(FLastMutations);
  end;
  // Sort/remap remain indivisible, with retained read-only scanning between.
  if Assigned(FMasterScan) then begin
    FMasterScan.Apply;
    FreeAndNil(FMasterScan);
    FMasterDepth := 0;
    planned := 1; applied := 0; skipped := 0;
    // Native clean preserves retained master order; only removal changes it.
    if FFile.MasterCount[True] <> FMasterCountBefore then applied := 1 else skipped := 1;
  end else
    xeAutomationMasterHygieneInMemory(FFile, not FDryRun, sort, planned, applied, skipped);
  operation.I['applied'] := applied; operation.I['skipped'] := skipped;
  operation.B['complete'] := True;
  if FDryRun then operation.S['outcome'] := 'planned'
  else if applied > 0 then operation.S['outcome'] := 'applied'
  else operation.S['outcome'] := 'skipped';
  Inc(FApplied, applied); Inc(FSkipped, skipped);
  FRow.I['applied'] := FRow.I['applied'] + applied;
  FRow.I['skipped'] := FRow.I['skipped'] + skipped;
  if sort then FPhase := cpCleanMasters
  else begin
    FRow.B['workComplete'] := True;
    FPhase := cpMasterReport;
  end;
end;

procedure TCombinedStepper.PublishOperation(const findings: TJsonArray);
var
  code, messageText, action, reason: string;
  planned, applied, skipped: Integer;
begin
  planned := FRow.I['planned']; applied := FRow.I['applied']; skipped := FRow.I['skipped'];
  reason := '';
  if FDryRun then begin action := 'planned'; reason := 'dry_run'; end
  else if applied > 0 then action := 'applied'
  else begin action := 'skipped'; reason := 'no_change'; end;
  if FPhase = cpItmReport then begin
    if FDryRun then begin
      code := xeAutomationFindingCleaningItmRecordsPlanned;
      messageText := Format('Planned ITM cleaning for %s', [FFile.FileName]);
    end else if applied > 0 then begin
      code := xeAutomationFindingCleaningItmRecordsRemoved;
      messageText := Format('Removed %d ITM records from %s', [applied, FFile.FileName]);
    end else begin
      code := xeAutomationFindingCleaningItmRecordsSkipped;
      messageText := Format('No removable ITM records found in %s', [FFile.FileName]);
    end;
  end else if FPhase = cpUdrReport then begin
    if FDryRun then begin
      code := xeAutomationFindingCleaningDeletedRefsPlanned;
      messageText := Format('Planned deleted-reference cleaning for %s', [FFile.FileName]);
    end else if applied > 0 then begin
      code := xeAutomationFindingCleaningDeletedRefsUndeletedDisabled;
      messageText := Format('Undeleted and disabled %d references in %s', [applied, FFile.FileName]);
    end else begin
      code := xeAutomationFindingCleaningDeletedRefsSkipped;
      messageText := Format('No cleanable deleted references found in %s', [FFile.FileName]);
    end;
  end else begin
    if FDryRun then begin
      code := xeAutomationFindingCleaningMastersSortCleanPlanned;
      messageText := Format('Planned sort and clean masters for %s', [FFile.FileName]);
    end else if applied > 0 then begin
      code := xeAutomationFindingCleaningMastersSortCleanApplied;
      messageText := Format('Applied sort and clean masters for %s', [FFile.FileName]);
    end else begin
      code := xeAutomationFindingCleaningMastersSortCleanSkipped;
      messageText := Format('No master list changes were needed for %s', [FFile.FileName]);
    end;
  end;
  xeAutomationAddCleaningFinding(findings, FKind, 'info', code, messageText,
    FFile.FileName, action, reason, planned, applied, skipped);
  if (FPhase = cpUdrReport) and (FDeletedNavmesh > 0) then
    xeAutomationAddCleaningFinding(findings, FKind, 'warning', xeAutomationFindingCleaningDeletedNavmeshSkipped,
      Format('Skipped %d deleted NavMeshes in %s', [FDeletedNavmesh, FFile.FileName]),
      FFile.FileName, 'skipped', 'unsafe_navmesh', 0, 0, FDeletedNavmesh);
  FRow.B['complete'] := True;
  if FPhase = cpItmReport then FPhase := cpBeginUdr
  else if (FPhase = cpMasterReport) and (FKind = xeAutomationCleaningQuickAutoCleanKind) then FPhase := cpBeginItm
  else begin FPhase := cpComplete; FComplete := True; end;
end;

function TCombinedStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var
  timer: TStopwatch;
  plannedBefore, appliedBefore, skippedBefore: Integer;
  oldPhase: TCombinedPhase;
begin
  Result := FComplete;
  if FComplete then Exit;
  timer := TStopwatch.StartNew;
  Inc(FSteps); FLastWork := 0; FLastMutations := 0;
  plannedBefore := FPlanned; appliedBefore := FApplied; skippedBefore := FSkipped;
  try
    try
      if not Assigned(FFile) then begin
        FFile := xeAutomationRequirePluginFile(FFileName);
        if not FDryRun then xeAutomationRequireWritableCleaningTarget(FFile);
        summary.S['kind'] := FKind; summary.B['dryRun'] := FDryRun;
        summary.I['targets'] := summary.I['targets'] + 1;
        if not summary.Contains('dirtyFiles') then summary.A['dirtyFiles'].Clear;
        if FKind = xeAutomationCleaningQuickCleanKind then FPhase := cpBeginItm
        else begin BeginOperation('sort_and_clean_masters', resultData); FPhase := cpSort; end;
        Inc(FLastWork);
      end;
      while not FComplete and (FLastWork < xeAutomationJobStepWorkLimit) and
            (FLastMutations < xeAutomationSelectiveMutationStepLimit) and
            (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
        Inc(FLastWork); oldPhase := FPhase;
        case FPhase of
          cpSort: MasterOne(True);
          cpCleanMasters: if FDryRun then MasterOne(False) else BeginMasterScan;
          cpScanMasters: ScanMasterOne;
          cpApplyCleanMasters: MasterOne(False);
          cpMasterReport, cpItmReport, cpUdrReport: PublishOperation(findings);
          cpBeginItm: begin BeginOperation('remove_itm', resultData); BeginCollection(cpCollectItm); end;
          cpCollectItm: CollectOne(cpItm);
          cpItm: RecordOne(True);
          cpBeginUdr: begin BeginOperation('undelete_and_disable_refs', resultData); BeginCollection(cpCollectUdr); end;
          cpCollectUdr: CollectOne(cpUdr);
          cpUdr: RecordOne(False);
        end;
        if (oldPhase in [cpSort, cpCleanMasters, cpApplyCleanMasters]) or
           ((oldPhase = cpScanMasters) and (FPhase <> oldPhase)) or
           ((oldPhase in [cpCollectItm, cpCollectUdr]) and (FPhase <> oldPhase)) or
           ((oldPhase in [cpMasterReport, cpItmReport, cpUdrReport]) and (FPhase <> oldPhase)) then Break;
      end;
      Result := FComplete;
    except
      on E: Exception do begin
        failure.S['operationPhase'] := 'combined-cleaning';
        if Assigned(FRow) then failure.S['operation'] := FRow.S['operation'];
        if FLastLocator.Count > 0 then failure.O['locator'].Assign(FLastLocator)
        else failure.O['locator'].S['file'] := FFileName;
        failure.I['completedRecordsAndMasterChanges'] := FApplied;
        if Assigned(FRow) then begin
          if FPhase = cpSort then FRow.O['operations'].O['sort'].S['outcome'] := 'failed'
          else if FPhase in [cpCleanMasters, cpScanMasters, cpApplyCleanMasters] then
            FRow.O['operations'].O['cleanMasters'].S['outcome'] := 'failed';
          FRow.O['failure'].S['message'] := Copy(E.Message, 1, 4096);
          if Length(E.Message) > 4096 then begin
            FRow.O['failure'].B['messageTruncated'] := True;
            FRow.O['failure'].I['originalMessageCharacters'] := Length(E.Message);
          end;
          if E is ExeAutomationError then FRow.O['failure'].S['code'] := ExeAutomationError(E).Code
          else if E is EwbAutomationMasterScanCapacity then FRow.O['failure'].S['code'] := 'job_capacity'
          else if E is EwbAutomationMasterScanInvalidated then FRow.O['failure'].S['code'] := 'job_invalidated'
          else FRow.O['failure'].S['code'] := xeAutomationErrorInternalError;
        end;
        if E is EwbAutomationMasterScanCapacity then raise xeAutomationNewError('job_capacity', E.Message);
        if E is EwbAutomationMasterScanInvalidated then raise xeAutomationNewError('job_invalidated', E.Message);
        raise;
      end;
    end;
  finally
    summary.I['planned'] := summary.I['planned'] + FPlanned - plannedBefore;
    summary.I['applied'] := summary.I['applied'] + FApplied - appliedBefore;
    summary.I['skipped'] := summary.I['skipped'] + FSkipped - skippedBefore;
    summary.I['findings'] := findings.Count;
    if Assigned(FRow) then begin
      FRow.I['visitedElements'] := FVisited;
      FRow.I['collectedRecords'] := FCollected;
      FRow.I['processedRecords'] := FProcessed;
      if FRow.S['operation'] = 'undelete_and_disable_refs' then
        FRow.I['deletedNavmeshSkipped'] := FDeletedNavmesh;
      xeAutomationWriteMutationAudit(FRow.O['mutationState'], FStageSnapshot);
      FRow.B['dirtyAfter'] := FFile.Modified;
      FRow.B['changed'] := FRow.O['mutationState'].B['mutationsObserved'];
      if not FDryRun and FFile.Modified then begin
        // Preserve combined cleaning's existing dirtyBefore/requiresSave behavior,
        // including already dirty targets, while keeping the finer mutation audit.
        summary.B['changed'] := True; summary.B['requiresSave'] := True;
        xeAutomationAddDirtyFile(summary.A['dirtyFiles'], FFile);
      end else begin
        if not summary.Contains('changed') then summary.B['changed'] := False;
        if not summary.Contains('requiresSave') then summary.B['requiresSave'] := False;
      end;
    end;
  end;
end;

procedure TCombinedStepper.WriteProgress(const progress: TJsonObject);
const
  PhaseNames: array[TCombinedPhase] of string = ('sort-masters', 'clean-masters', 'scan-masters',
    'apply-clean-masters', 'master-report',
    'begin-itm', 'collect-itm', 'itm', 'itm-report', 'begin-udr', 'collect-udr', 'udr', 'udr-report', 'complete');
begin
  progress.S['fileName'] := FFileName; progress.B['fileComplete'] := FComplete;
  progress.S['phase'] := PhaseNames[FPhase];
  progress.I['visitedElements'] := FVisited; progress.I['collectedRecords'] := FCollected;
  progress.I['processedRecords'] := FProcessed; progress.I['retainedRecords'] := FRecords.Count;
  progress.I['retainedDepth'] := FStack.Count;
  progress.I['masterScanWorkUnits'] := FMasterScanWork;
  progress.I['masterScanWorkLimit'] := wbAutomationMasterScanWorkLimit;
  progress.I['masterNativeUsageCalls'] := FMasterNativeUnits;
  progress.I['masterRetainedDepth'] := FMasterDepth;
  progress.I['masterDepthLimit'] := wbAutomationMasterScanDepthLimit;
  progress.I['planned'] := FPlanned; progress.I['applied'] := FApplied; progress.I['skipped'] := FSkipped;
  progress.I['steps'] := FSteps; progress.I['lastWorkUnits'] := FLastWork;
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  progress.I['lastMutations'] := FLastMutations;
  progress.I['mutationLimit'] := xeAutomationSelectiveMutationStepLimit;
  progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.B['nativeCallsPreemptible'] := False;
  progress.S['retentionScope'] := 'current loaded file preorder roots; no selective 1000-record limit';
  if FLastLocator.Count > 0 then progress.O['lastRecord'].Assign(FLastLocator);
end;

function CreateCombinedStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin
  Result := TCombinedStepper.Create(kind, Trim(target.A['files'].S[0]), dry);
end;

procedure xeAutomationRunCleaningJob(const kind: string; const dry: Boolean; const target: TJsonObject;
  const findings: TJsonArray; const summary, resultData, failure: TJsonObject);
var
  stepper: TxeAutomationJobStepper;
  i: Integer;
begin
  for i := 0 to Pred(target.A['files'].Count) do begin
    stepper := TCombinedStepper.Create(kind, Trim(target.A['files'].S[i]), dry);
    try
      while not stepper.Advance(findings, summary, resultData, failure) do begin end;
    finally stepper.Free; end;
  end;
end;

procedure xeAutomationQuickCleanJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
begin
  xeAutomationRunCleaningJob(xeAutomationCleaningQuickCleanKind, ADryRun, ATarget, AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationQuickAutoCleanJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
begin
  xeAutomationRunCleaningJob(xeAutomationCleaningQuickAutoCleanKind, ADryRun, ATarget, AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationSortAndCleanMastersJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
begin
  xeAutomationRunCleaningJob(xeAutomationCleaningSortAndCleanMastersKind, ADryRun, ATarget, AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationRegisterCleaningCommands;
begin
  xeAutomationRegisterSelectiveCleaningJobs;
  // Capability advertising is registry-derived; the cleaning kinds become visible
  // only after these in-memory, explicit-save-safe handlers are linked.
  xeAutomationRegisterJobKindWithValidator(xeAutomationCleaningQuickCleanKind, xeAutomationQuickCleanJob,
    xeAutomationValidateCleaningStart);
  xeAutomationRegisterJobKindWithValidator(xeAutomationCleaningQuickAutoCleanKind, xeAutomationQuickAutoCleanJob,
    xeAutomationValidateCleaningStart);
  xeAutomationRegisterJobKindWithValidator(xeAutomationCleaningSortAndCleanMastersKind, xeAutomationSortAndCleanMastersJob,
    xeAutomationValidateCleaningStart);
  xeAutomationRegisterJobStepper(xeAutomationCleaningQuickCleanKind, CreateCombinedStepper);
  xeAutomationRegisterJobStepper(xeAutomationCleaningQuickAutoCleanKind, CreateCombinedStepper);
  xeAutomationRegisterJobStepper(xeAutomationCleaningSortAndCleanMastersKind, CreateCombinedStepper);
end;

end.
