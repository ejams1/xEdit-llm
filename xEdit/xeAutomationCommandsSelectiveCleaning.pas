{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsSelectiveCleaning;
interface
const
  xeAutomationSelectiveMutationStepLimit = 16;
procedure xeAutomationRegisterSelectiveCleaningJobs;
implementation
uses Classes, SysUtils, System.Diagnostics, System.Generics.Collections, JsonDataObjects,
  wbInterface, xeMainForm, xeAutomationDataLookup, xeAutomationErrors,
  xeAutomationJobs, xeAutomationMutationPolicy, xeAutomationMutationAudit,
  xeAutomationRecordComparison;

const
  ItmKind = 'cleaning.remove_itm';
  UdrKind = 'cleaning.undelete_and_disable_refs';

procedure ValidateStart(var dry: Boolean; const specified: Boolean;
  const target, options: TJsonObject);
var names: TStringList; fileRef: IwbFile; files: TJsonArray; i, count: Integer;
begin
  if (wbGameMode = gmTES3) or wbTranslationMode then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Selective cleaning requires non-TES3 plugin edit definitions, translation mode off');
  if not Assigned(target) or not target.Contains('files') or
     (target.Types['files'] <> jdtArray) then
    raise xeAutomationInvalidRequest('target.files must be a plugin name array');
  if target.Count <> 1 then raise xeAutomationInvalidRequest('Selective cleaning target accepts only files');
  if Assigned(options) and (options.Count > 0) then
    raise xeAutomationInvalidRequest('Selective cleaning uses native session UDR settings; no options accepted');
  files := target.A['files'];
  if (files.Count < 1) or (files.Count > 8) then raise xeAutomationInvalidRequest('Select 1..8 files');
  if not specified then dry := True;
  names := TStringList.Create;
  try
    names.CaseSensitive := False; count := 0;
    // Resolve every target at start, so an invalid/protected later file cannot
    // leave earlier files changed. The job manager repeats writable preflight.
    for i := 0 to files.Count - 1 do begin
      if files.Types[i] <> jdtString then raise xeAutomationInvalidRequest('files entries must be strings');
      fileRef := xeAutomationRequirePluginFile(Trim(files.S[i]));
      if names.IndexOf(fileRef.FileName) >= 0 then raise xeAutomationInvalidRequest('Duplicate cleaning target');
      names.Add(fileRef.FileName);
      Inc(count, fileRef.RecordCount);
      if count > 1000 then raise xeAutomationNewError('cleaning_capacity', 'Selective cleaning scans at most 1000 records');
      if not dry then xeAutomationRequireWritableCleaningTarget(fileRef);
    end;
  finally names.Free; end;
end;

type
  TSelectivePhase = (spMasters, spPlan, spApply, spFinish, spComplete);
  TSelectiveStepper = class(TxeAutomationJobStepper)
  private
    FKind, FFileName: string;
    FDryRun: Boolean;
    FFile: IwbFile;
    FPlan: TList<IwbMainRecord>;
    FFileRow: TJsonObject; // Owned by the durable result, never by this cursor.
    FSnapshot: TxeAutomationMutationSnapshot;
    FPhase: TSelectivePhase;
    FMasterIndex, FRecordIndex, FTotalRecords, FApplyRowIndex: Integer;
    FPlanned, FApplied, FSkipped, FFailed, FSteps, FLastWorkUnits, FLastMutations: Integer;
    FPlanningComplete, FComplete: Boolean;
    procedure Initialize(const summary, resultData: TJsonObject);
    procedure PublishRow(const findings: TJsonArray; const row: TJsonObject);
    procedure PlanNext(const findings: TJsonArray; const failure: TJsonObject);
    procedure CheckUdrSettings;
    procedure ApplyNext(const findings: TJsonArray; const failure: TJsonObject);
    procedure PublishCounts(const findings: TJsonArray);
  public
    constructor Create(const kind, fileName: string; const dry: Boolean);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TSelectiveStepper.Create(const kind, fileName: string; const dry: Boolean);
begin
  inherited Create;
  FKind := kind;
  FFileName := fileName;
  FDryRun := dry;
  FPlan := TList<IwbMainRecord>.Create;
end;

destructor TSelectiveStepper.Destroy;
begin
  FPlan.Free;
  FSnapshot.Files := nil;
  FFile := nil;
  inherited;
end;

procedure TSelectiveStepper.Initialize(const summary, resultData: TJsonObject);
begin
  FFile := xeAutomationRequirePluginFile(FFileName);
  if not FDryRun then xeAutomationRequireWritableCleaningTarget(FFile);
  FSnapshot := xeAutomationCaptureMutationSnapshot;
  FTotalRecords := FFile.RecordCount;
  summary.S['kind'] := FKind;
  summary.B['dryRun'] := FDryRun;
  summary.I['targets'] := summary.I['targets'] + 1;
  summary.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush';
  summary.S['cancellation'] := 'between-records; native mutation calls indivisible';
  if not summary.Contains('dirtyFiles') then summary.A['dirtyFiles'].Clear;
  FFileRow := resultData.A['files'].AddObject;
  FFileRow.S['fileName'] := FFile.FileName;
  FFileRow.S['operation'] := FKind;
  FFileRow.B['dirtyBefore'] := FFile.Modified;
  FFileRow.B['complete'] := False;
  FFileRow.B['planningComplete'] := False;
  FFileRow.A['records'].Clear;
  FFileRow.A['masters'].Clear;
  if FKind = UdrKind then
    with FFileRow.O['nativeSettings'] do begin
      B['setZ'] := wbUDRSetZ;
      F['z'] := wbUDRSetZValue;
      B['setXESP'] := wbUDRSetXESP;
      B['setScale'] := wbUDRSetScale;
      F['scale'] := wbUDRSetScaleValue;
      B['setMSTT'] := wbUDRSetMSTT;
      S['msttFormId'] := IntToHex(wbUDRSetMSTTValue, 8);
    end;
end;

procedure TSelectiveStepper.PublishRow(const findings: TJsonArray; const row: TJsonObject);
var
  finding: TJsonObject;
begin
  finding := TJsonObject.Create;
  try
    finding.S['source'] := FKind;
    finding.S['severity'] := 'info';
    finding.S['code'] := 'selective_cleaning_record';
    finding.O['target'].Assign(row.O['locator']);
    finding.S['signature'] := row.S['signature'];
    finding.S['outcome'] := row.S['outcome'];
    if row.Contains('reason') then finding.S['reason'] := row.S['reason'];
    if row.Contains('deletedAfter') then finding.B['deletedAfter'] := row.B['deletedAfter'];
    if row.Contains('initiallyDisabledAfter') then finding.B['initiallyDisabledAfter'] := row.B['initiallyDisabledAfter'];
    // Findings are immutable event copies. Later apply updates the durable row,
    // never a previously admitted finding or its cached byte accounting.
    xeAutomationAppendJobFinding(findings, finding);
    finding := nil;
  finally
    finding.Free;
  end;
end;

procedure TSelectiveStepper.PlanNext(const findings: TJsonArray; const failure: TJsonObject);
var
  recordRef: IwbMainRecord;
  row: TJsonObject;
  reason: string;
  navmesh: Boolean;
begin
  if FRecordIndex >= FTotalRecords then begin
    FPlanningComplete := True;
    FFileRow.B['planningComplete'] := True;
    if FDryRun then FPhase := spFinish else FPhase := spApply;
    Exit;
  end;
  recordRef := FFile.Records[FRecordIndex];
  Inc(FRecordIndex);
  if not Assigned(recordRef) then Exit;
  try
    reason := '';
    if FKind = ItmKind then begin
      if not xeAutomationRecordIsIdenticalToMaster(recordRef) then Exit;
      reason := xeAutomationIdenticalRecordRemovalReason(recordRef);
    end else begin
      if not xeAutomationRecordIsDeletedRefCandidate(recordRef) then Exit;
      if not xeAutomationDeletedRefCanBeCleaned(recordRef, navmesh) then begin
        if navmesh then reason := 'unsafe-navmesh' else reason := 'native-ineligible';
      end else if not recordRef.IsEditable then reason := 'not-editable';
    end;
    row := FFileRow.A['records'].AddObject;
    row.O['locator'].S['file'] := FFile.FileName;
    row.O['locator'].S['formId'] := recordRef.LoadOrderFormID.ToString(False);
    row.O['locator'].S['path'] := '';
    row.S['signature'] := recordRef.Signature;
    if reason <> '' then begin
      row.S['outcome'] := 'skipped';
      row.S['reason'] := reason;
      Inc(FSkipped);
    end else begin
      row.S['outcome'] := 'planned';
      row.I['planIndex'] := FPlan.Count;
      FPlan.Add(recordRef);
      Inc(FPlanned);
    end;
    PublishRow(findings, row);
  except
    failure.S['operationPhase'] := 'record-planning';
    failure.O['locator'].S['file'] := FFile.FileName;
    failure.O['locator'].S['formId'] := recordRef.LoadOrderFormID.ToString(False);
    failure.O['locator'].S['path'] := '';
    raise;
  end;
end;

procedure TSelectiveStepper.CheckUdrSettings;
begin
  with FFileRow.O['nativeSettings'] do
    if (B['setZ'] <> wbUDRSetZ) or (F['z'] <> wbUDRSetZValue) or
       (B['setXESP'] <> wbUDRSetXESP) or (B['setScale'] <> wbUDRSetScale) or
       (F['scale'] <> wbUDRSetScaleValue) or (B['setMSTT'] <> wbUDRSetMSTT) or
       (S['msttFormId'] <> IntToHex(wbUDRSetMSTTValue, 8)) then
      raise xeAutomationNewError('job_state_changed', 'Native UDR settings changed during planning; restart the job');
end;

procedure TSelectiveStepper.ApplyNext(const findings: TJsonArray; const failure: TJsonObject);
var
  row: TJsonObject;
  recordRef: IwbMainRecord;
  planIndex: Integer;
begin
  if FApplyRowIndex >= FFileRow.A['records'].Count then begin
    FPhase := spFinish;
    Exit;
  end;
  row := FFileRow.A['records'].O[FApplyRowIndex];
  Inc(FApplyRowIndex);
  if row.S['outcome'] <> 'planned' then Exit;
  planIndex := row.I['planIndex'];
  recordRef := FPlan[planIndex];
  row.S['outcome'] := 'attempted';
  try
    xeAutomationRequireWritableCleaningTarget(FFile);
    if FKind = ItmKind then begin
      if not xeAutomationRecordIsIdenticalToMaster(recordRef) or
         (xeAutomationIdenticalRecordRemovalReason(recordRef) <> '') then
        raise xeAutomationStateConflict('ITM no longer removable');
      Inc(FLastMutations);
      recordRef.Remove;
    end else begin
      CheckUdrSettings;
      Inc(FLastMutations);
      xeAutomationUndeleteAndDisableRefInMemory(recordRef);
      row.B['deletedAfter'] := recordRef.IsDeleted;
      row.B['initiallyDisabledAfter'] := recordRef.IsInitiallyDisabled;
      if row.B['deletedAfter'] or not row.B['initiallyDisabledAfter'] then
        raise xeAutomationStateConflict('UDR flags did not match native readback');
    end;
    row.S['outcome'] := 'applied';
    Inc(FApplied);
  except
    on E: Exception do begin
      row.S['outcome'] := 'failed';
      Inc(FFailed);
      row.S['message'] := Copy(E.Message, 1, 4096);
      if Length(E.Message) > 4096 then begin
        row.B['messageTruncated'] := True;
        row.I['originalMessageCharacters'] := Length(E.Message);
        failure.B['messageTruncated'] := True;
        failure.I['originalMessageCharacters'] := Length(E.Message);
      end;
      if E is ExeAutomationError then begin
        failure.S['code'] := ExeAutomationError(E).Code;
        if Assigned(ExeAutomationError(E).Details) then
          failure.O['details'].Assign(ExeAutomationError(E).Details);
      end
      else failure.S['code'] := xeAutomationErrorInternalError;
      failure.S['message'] := Copy(E.Message, 1, 4096);
      failure.S['phase'] := FKind;
      failure.S['operationPhase'] := 'record-apply';
      failure.I['completedRecords'] := FApplied;
      failure.O['locator'].Assign(row.O['locator']);
    end;
  end;
  FPlan[planIndex] := nil;
  if failure.Count = 0 then begin
    // A capacity refusal here is after a completed native mutation. Keep the
    // applied row/count even if its event cannot be admitted; never mark rollback.
    try
      PublishRow(findings, row);
    except
      failure.S['operationPhase'] := 'finding-retention-after-apply';
      failure.I['completedRecords'] := FApplied;
      failure.O['locator'].Assign(row.O['locator']);
      raise;
    end;
  end;
end;

procedure TSelectiveStepper.PublishCounts(const findings: TJsonArray);
var
  finding: TJsonObject;
begin
  finding := TJsonObject.Create;
  try
    finding.S['source'] := FKind;
    finding.S['severity'] := 'info';
    finding.S['code'] := 'selective_cleaning_counts';
    finding.O['target'].S['file'] := FFile.FileName;
    finding.O['counts'].I['planned'] := FPlanned;
    finding.O['counts'].I['applied'] := FApplied;
    finding.O['counts'].I['skipped'] := FSkipped;
    xeAutomationAppendJobFinding(findings, finding);
    finding := nil;
  finally
    finding.Free;
  end;
end;

function TSelectiveStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var
  timer: TStopwatch;
  plannedBefore, appliedBefore, skippedBefore, i: Integer;
  oldPhase: TSelectivePhase;
  dirtyListed: Boolean;
begin
  Result := FComplete;
  if FComplete then Exit;
  timer := TStopwatch.StartNew;
  Inc(FSteps);
  FLastWorkUnits := 0;
  FLastMutations := 0;
  plannedBefore := FPlanned;
  appliedBefore := FApplied;
  skippedBefore := FSkipped;
  try
    if not Assigned(FFile) then begin
      Initialize(summary, resultData);
      Inc(FLastWorkUnits);
    end;
    while not FComplete and (failure.Count = 0) and
          (FLastWorkUnits < xeAutomationJobStepWorkLimit) and
          (FLastMutations < xeAutomationSelectiveMutationStepLimit) and
          (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
      Inc(FLastWorkUnits);
      oldPhase := FPhase;
      case FPhase of
        spMasters:
          if FMasterIndex < FFile.MasterCount[True] then begin
            FFileRow.A['masters'].Add(FFile.Masters[FMasterIndex, True].FileName);
            Inc(FMasterIndex);
          end else FPhase := spPlan;
        spPlan: PlanNext(findings, failure);
        spApply: ApplyNext(findings, failure);
        spFinish: begin
          PublishCounts(findings);
          FComplete := True;
          FPhase := spComplete;
        end;
      end;
      // Expose a complete classification boundary before the first mutation.
      if (oldPhase = spPlan) and (FPhase <> spPlan) then Break;
    end;
    Result := FComplete;
  finally
    summary.I['planned'] := summary.I['planned'] + FPlanned - plannedBefore;
    summary.I['applied'] := summary.I['applied'] + FApplied - appliedBefore;
    summary.I['skipped'] := summary.I['skipped'] + FSkipped - skippedBefore;
    summary.I['findings'] := findings.Count;
    if Assigned(FFileRow) then begin
      FFileRow.B['complete'] := FComplete;
      FFileRow.I['planned'] := FPlanned;
      FFileRow.I['applied'] := FApplied;
      FFileRow.I['skipped'] := FSkipped;
      FFileRow.I['scannedRecords'] := FRecordIndex;
      xeAutomationWriteMutationAudit(FFileRow.O['mutationState'], FSnapshot);
      FFileRow.B['dirtyAfter'] := FFile.Modified;
      summary.B['changed'] := summary.B['changed'] or FFileRow.O['mutationState'].B['mutationsObserved'];
      summary.B['requiresSave'] := summary.B['requiresSave'] or
        (FFileRow.O['mutationState'].B['mutationsObserved'] and FFile.Modified);
      if not FDryRun and FFileRow.O['mutationState'].B['mutationsObserved'] and FFile.Modified then begin
        dirtyListed := False;
        for i := 0 to summary.A['dirtyFiles'].Count - 1 do
          if SameText(summary.A['dirtyFiles'].S[i], FFile.FileName) then dirtyListed := True;
        if not dirtyListed then summary.A['dirtyFiles'].Add(FFile.FileName);
      end;
    end;
  end;
end;

procedure TSelectiveStepper.WriteProgress(const progress: TJsonObject);
const
  PhaseNames: array[TSelectivePhase] of string = ('masters', 'planning', 'apply', 'finish', 'complete');
begin
  progress.S['fileName'] := FFileName;
  progress.B['fileComplete'] := FComplete;
  progress.B['planningComplete'] := FPlanningComplete;
  progress.S['phase'] := PhaseNames[FPhase];
  progress.I['scannedRecords'] := FRecordIndex;
  progress.I['totalRecords'] := FTotalRecords;
  progress.I['planned'] := FPlanned;
  progress.I['applied'] := FApplied;
  progress.I['skipped'] := FSkipped;
  progress.I['remainingPlanned'] := FPlanned - FApplied - FFailed;
  progress.I['steps'] := FSteps;
  progress.I['lastWorkUnits'] := FLastWorkUnits;
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  progress.I['lastMutations'] := FLastMutations;
  progress.I['mutationLimit'] := xeAutomationSelectiveMutationStepLimit;
  progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.B['nativeCallsPreemptible'] := False;
end;

function CreateSelectiveStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin
  Result := TSelectiveStepper.Create(kind, Trim(target.A['files'].S[0]), dry);
end;

procedure Run(const kind: string; dry: Boolean; const target: TJsonObject;
  const findings: TJsonArray; const summary, resultData, failure: TJsonObject);
var
  stepper: TxeAutomationJobStepper;
begin
  // Compatibility handlers share semantics; registered jobs retain the factory
  // cursor and never synchronously drain the selected file here.
  stepper := CreateSelectiveStepper(kind, dry, True, target, nil);
  try
    while not stepper.Advance(findings, summary, resultData, failure) and (failure.Count = 0) do begin end;
  finally
    stepper.Free;
  end;
end;

procedure ItmJob(const jobId: string; const dry, specified: Boolean;
  const target, options: TJsonObject; const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject);
begin Run(ItmKind, dry, target, findings, summary, resultData, failure); end;

procedure UdrJob(const jobId: string; const dry, specified: Boolean;
  const target, options: TJsonObject; const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject);
begin Run(UdrKind, dry, target, findings, summary, resultData, failure); end;

procedure xeAutomationRegisterSelectiveCleaningJobs;
begin
  xeAutomationRegisterJobKindWithValidator(ItmKind, ItmJob, ValidateStart);
  xeAutomationRegisterJobKindWithValidator(UdrKind, UdrJob, ValidateStart);
  xeAutomationRegisterJobStepper(ItmKind, CreateSelectiveStepper);
  xeAutomationRegisterJobStepper(UdrKind, CreateSelectiveStepper);
end;
end.
