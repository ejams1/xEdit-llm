{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationJobs;

interface

uses
  JsonDataObjects;

type
  TxeAutomationJobStartValidator = procedure(var ADryRun: Boolean; const ADryRunSpecified: Boolean; const ATarget, AOptions: TJsonObject);
  TxeAutomationJobHandler = procedure(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean; const ATarget, AOptions: TJsonObject;
    const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);

procedure xeAutomationRegisterJobKind(const AKind: string; const AHandler: TxeAutomationJobHandler);
procedure xeAutomationRegisterJobKindWithValidator(const AKind: string; const AHandler: TxeAutomationJobHandler;
  const AValidator: TxeAutomationJobStartValidator; const AWorkKey: string = 'files');
procedure xeAutomationAssertJobCommandAllowed(const ACommand: string);
function xeAutomationListJobKinds: TArray<string>;
function xeAutomationStartJob(const AKind: string; const ADryRun, ADryRunSpecified: Boolean; const ATarget, AOptions: TJsonObject): TJsonObject;
function xeAutomationGetJob(const AJobId: string): TJsonObject;
function xeAutomationGetJobFindings(const AJobId: string; const AOffset, ALimit: Integer): TJsonObject;
function xeAutomationCancelJob(const AJobId: string): TJsonObject;
function xeAutomationDiscardJob(const AJobId: string): TJsonObject;

implementation

uses
  System.Generics.Collections,
  SysUtils,
  Classes,
  wbInterface,
  xeAutomationDataLookup,
  xeAutomationMutationPolicy,
  xeAutomationMutationAudit,
  xeAutomationRecordQueries,
  xeAutomationErrors;

const
  xeAutomationTerminalJobRetention = 16;
  xeAutomationMaxJobFindings = 5000;
  xeAutomationMaxJobFindingBytes = 1048576;

type
  TxeAutomationJobKindRegistration = record
    Handler: TxeAutomationJobHandler;
    Validator: TxeAutomationJobStartValidator;
    WorkKey: string;
  end;

  TxeAutomationJobState = (xajsQueued, xajsRunning, xajsSucceeded, xajsFailed, xajsCancelRequested, xajsCanceled);

  TxeAutomationJob = class
  public
    Id: string;
    Kind: string;
    State: TxeAutomationJobState;
    Sequence: Int64;
    DryRun: Boolean;
    DryRunSpecified: Boolean;
    Target: TJsonObject;
    Options: TJsonObject;
    SummaryData: TJsonObject;
    ResultData: TJsonObject;
    FailureData: TJsonObject;
    Findings: TJsonArray;
    WorkIndex: Integer;
    TotalWork: Integer;
    WorkKey: string;
    StartMutation: TxeAutomationMutationSnapshot;
    ExpectedRevision, ExpectedSemanticRevision: UInt64;
    PreflightDone: Boolean;
    constructor Create;
    destructor Destroy; override;
    function IsTerminal: Boolean;
    function IsCancelable: Boolean;
  end;

var
  xeAutomationJobKinds: TDictionary<string, TxeAutomationJobKindRegistration>;
  xeAutomationJobList: TObjectList<TxeAutomationJob>;
  xeAutomationNextJobId: Integer;
  xeAutomationNextJobSequence: Int64;
  xeAutomationActiveJob: TxeAutomationJob;

procedure xeAutomationAssertJobCommandAllowed(const ACommand: string);
begin
  if not Assigned(xeAutomationActiveJob) or xeAutomationActiveJob.IsTerminal then
    Exit;
  if (Copy(ACommand, 1, 5) = 'jobs.') or (Copy(ACommand, 1, 7) = 'system.') or
     (Copy(ACommand, 1, 12) = 'session.get_') or
     (ACommand = 'records.list') or (ACommand = 'records.get') or
     (ACommand = 'records.references') or (ACommand = 'records.referenced_by') or
     (ACommand = 'records.conflict_status') or
     (ACommand = 'elements.get') or (ACommand = 'elements.get_value') or
     (ACommand = 'elements.children') or
     (ACommand = 'batch.read') or
     (ACommand = 'files.list') or (ACommand = 'files.get') then
    Exit;
  // A pending plan owns the loaded graph. Save/flush, scripts and other edits
  // must wait until completion/cancellation; read-only probes remain available.
  raise xeAutomationNewError('job_busy', 'Cancel or finish the active job before changing the loaded session');
end;

constructor TxeAutomationJob.Create;
begin
  inherited;
  Target := TJsonObject.Create;
  Options := TJsonObject.Create;
  SummaryData := TJsonObject.Create;
  ResultData := TJsonObject.Create;
  FailureData := TJsonObject.Create;
  Findings := TJsonArray.Create;
end;

destructor TxeAutomationJob.Destroy;
begin
  Findings.Free;
  FailureData.Free;
  ResultData.Free;
  SummaryData.Free;
  Options.Free;
  Target.Free;
  inherited;
end;

function TxeAutomationJob.IsTerminal: Boolean;
begin
  Result := State in [xajsSucceeded, xajsFailed, xajsCanceled];
end;

function TxeAutomationJob.IsCancelable: Boolean;
begin
  // Native xEdit operations are advanced only on the main request path. Once a
  // handler is running there is no safe mid-operation interrupt point to expose.
  Result := State in [xajsQueued, xajsRunning, xajsCancelRequested];
end;

function xeAutomationNormalizeJobKind(const AKind: string): string;
begin
  Result := LowerCase(Trim(AKind));
end;

function xeAutomationGetJobKinds: TDictionary<string, TxeAutomationJobKindRegistration>;
begin
  if not Assigned(xeAutomationJobKinds) then
    xeAutomationJobKinds := TDictionary<string, TxeAutomationJobKindRegistration>.Create;
  Result := xeAutomationJobKinds;
end;

function xeAutomationGetJobs: TObjectList<TxeAutomationJob>;
begin
  if not Assigned(xeAutomationJobList) then
    xeAutomationJobList := TObjectList<TxeAutomationJob>.Create(True);
  Result := xeAutomationJobList;
end;

function xeAutomationJobStateName(const AState: TxeAutomationJobState): string;
begin
  case AState of
    xajsQueued: Result := 'queued';
    xajsRunning: Result := 'running';
    xajsSucceeded: Result := 'succeeded';
    xajsFailed: Result := 'failed';
    xajsCancelRequested: Result := 'cancel_requested';
    xajsCanceled: Result := 'canceled';
  else
    Result := 'failed';
  end;
end;

procedure xeAutomationRegisterJobKindWithValidator(const AKind: string; const AHandler: TxeAutomationJobHandler;
  const AValidator: TxeAutomationJobStartValidator; const AWorkKey: string);
var
  lKind: string;
  lRegistration: TxeAutomationJobKindRegistration;
begin
  if not Assigned(AHandler) then
    raise Exception.Create('Automation job handler is required');

  lKind := xeAutomationNormalizeJobKind(AKind);
  if lKind = '' then
    raise Exception.Create('Automation job kind is required');
  if xeAutomationGetJobKinds.ContainsKey(lKind) then
    raise Exception.CreateFmt('Automation job kind already registered: %s', [AKind]);

  lRegistration.Handler := AHandler;
  lRegistration.Validator := AValidator;
  if (AWorkKey <> 'files') and (AWorkKey <> 'worldspaces') and (AWorkKey <> 'steps') then
    raise Exception.Create('Unsupported automation job work key');
  lRegistration.WorkKey := AWorkKey;
  xeAutomationGetJobKinds.Add(lKind, lRegistration);
end;

procedure xeAutomationRegisterJobKind(const AKind: string; const AHandler: TxeAutomationJobHandler);
begin
  xeAutomationRegisterJobKindWithValidator(AKind, AHandler, nil);
end;

function xeAutomationListJobKinds: TArray<string>;
var
  lKinds: TStringList;
  lPair: TPair<string, TxeAutomationJobKindRegistration>;
  i: Integer;
begin
  lKinds := TStringList.Create;
  try
    for lPair in xeAutomationGetJobKinds do
      lKinds.Add(lPair.Key);
    lKinds.Sort;

    SetLength(Result, lKinds.Count);
    for i := 0 to Pred(lKinds.Count) do
      Result[i] := lKinds[i];
  finally
    lKinds.Free;
  end;
end;

function xeAutomationFindJob(const AJobId: string): TxeAutomationJob;
var
  lJob: TxeAutomationJob;
begin
  Result := nil;
  for lJob in xeAutomationGetJobs do
    if SameText(lJob.Id, Trim(AJobId)) then
      Exit(lJob);
end;

function xeAutomationRequireJob(const AJobId: string): TxeAutomationJob;
begin
  Result := xeAutomationFindJob(AJobId);
  if not Assigned(Result) then
    raise xeAutomationNewError(xeAutomationErrorJobNotFound, Format('Automation job not found: %s', [AJobId]));
end;

procedure xeAutomationCopyJsonObject(const ASource, ADest: TJsonObject);
begin
  ADest.Clear;
  if Assigned(ASource) then
    ADest.Assign(ASource);
end;

function xeAutomationNewJobSnapshot(const AJob: TxeAutomationJob): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.S['jobId'] := AJob.Id;
  Result.S['kind'] := AJob.Kind;
  Result.S['state'] := xeAutomationJobStateName(AJob.State);
  Result.B['terminal'] := AJob.IsTerminal;
  Result.B['cancelable'] := AJob.IsCancelable;
  Result.B['dryRun'] := AJob.DryRun;
  Result.B['dryRunSpecified'] := AJob.DryRunSpecified;
  Result.L['sequence'] := AJob.Sequence;
  Result.I['findingCount'] := AJob.Findings.Count;
  with Result.O['progress'] do begin
    I['completed'] := AJob.WorkIndex;
    I['total'] := AJob.TotalWork;
    I['remaining'] := AJob.TotalWork - AJob.WorkIndex;
    if AJob.WorkKey = 'files' then begin
      S['unit'] := 'target-file';
      if AJob.WorkIndex < AJob.TotalWork then S['nextFile'] := AJob.Target.A['files'].S[AJob.WorkIndex];
    end else if AJob.WorkKey = 'worldspaces' then begin
      S['unit'] := 'worldspace';
      if AJob.WorkIndex < AJob.TotalWork then O['nextWorldspace'].Assign(AJob.Target.A['worldspaces'].O[AJob.WorkIndex]);
    end else begin
      S['unit'] := 'native-stage';
      if AJob.WorkIndex < AJob.TotalWork then O['nextStep'].Assign(AJob.Target.A[AJob.WorkKey].O[AJob.WorkIndex]);
    end;
  end;
  if AJob.SummaryData.Count > 0 then
    Result.O['summary'].Assign(AJob.SummaryData);
  if AJob.ResultData.Count > 0 then
    Result.O['result'].Assign(AJob.ResultData);
  if AJob.FailureData.Count > 0 then
    Result.O['failure'].Assign(AJob.FailureData);
end;

procedure xeAutomationWriteFindingJobFields(const ATarget: TJsonObject; const AJob: TxeAutomationJob);
begin
  ATarget.S['jobId'] := AJob.Id;
  ATarget.S['kind'] := AJob.Kind;
  ATarget.S['state'] := xeAutomationJobStateName(AJob.State);
  ATarget.B['terminal'] := AJob.IsTerminal;
  ATarget.B['cancelable'] := AJob.IsCancelable;
  ATarget.B['dryRun'] := AJob.DryRun;
end;

procedure xeAutomationAddFindingCopy(const ADest: TJsonArray; const ASource: TJsonArray; const AIndex: Integer);
begin
  case ASource.Types[AIndex] of
    jdtString: ADest.Add(ASource.S[AIndex]);
    jdtInt: ADest.Add(ASource.I[AIndex]);
    jdtLong: ADest.Add(ASource.L[AIndex]);
    jdtULong: ADest.Add(ASource.U[AIndex]);
    jdtFloat: ADest.Add(ASource.F[AIndex]);
    jdtDateTime: ADest.Add(ASource.D[AIndex]);
    jdtUtcDateTime: ADest.AddUtcDateTime(ASource.DUtc[AIndex]);
    jdtBool: ADest.Add(ASource.B[AIndex]);
    jdtArray: ADest.Add(ASource.A[AIndex].Clone);
    jdtObject: ADest.Add(ASource.O[AIndex].Clone);
  else
    ADest.AddObject(nil);
  end;
end;

procedure xeAutomationMergeJobObject(const ADest, ASource: TJsonObject);
var
  lName: string;
  lArray: TJsonArray;
  i, j: Integer;
begin
  // Each existing handler writes a complete singleton result. Aggregate its
  // per-file counts and file arrays once, preserving completed steps on cancel.
  for i := 0 to ASource.Count - 1 do begin
    lName := ASource.Names[i];
    case ASource.Types[lName] of
      jdtInt, jdtLong: ADest.L[lName] := ADest.L[lName] + ASource.L[lName];
      jdtULong: ADest.U[lName] := ADest.U[lName] + ASource.U[lName];
      jdtFloat: ADest.F[lName] := ADest.F[lName] + ASource.F[lName];
      jdtBool: ADest.B[lName] := ADest.B[lName] or ASource.B[lName];
      jdtString:
        if not ADest.Contains(lName) then
          ADest.S[lName] := ASource.S[lName];
      jdtObject: xeAutomationMergeJobObject(ADest.O[lName], ASource.O[lName]);
      jdtArray: begin
        lArray := ADest.A[lName];
        for j := 0 to ASource.A[lName].Count - 1 do
          xeAutomationAddFindingCopy(lArray, ASource.A[lName], j);
      end;
    end;
  end;
end;

procedure xeAutomationRunNextFile(const AJob: TxeAutomationJob;
  const ARegistration: TxeAutomationJobKindRegistration);
var
  lTarget, lSummary, lResult, lFailure: TJsonObject;
  lFindings: TJsonArray;
  i: Integer;
begin
  lTarget := AJob.Target.Clone;
  lSummary := TJsonObject.Create;
  lResult := TJsonObject.Create;
  lFailure := TJsonObject.Create;
  lFindings := TJsonArray.Create;
  try
    // Legacy jobs retain file units; native LOD advances an explicit worldspace
    // locator per poll instead of treating a plugin as an entire generation job.
    lTarget.A[AJob.WorkKey].Clear;
    if AJob.WorkKey = 'files' then lTarget.A['files'].Add(AJob.Target.A['files'].S[AJob.WorkIndex])
    else lTarget.A[AJob.WorkKey].AddObject.Assign(AJob.Target.A[AJob.WorkKey].O[AJob.WorkIndex]);
    ARegistration.Handler(AJob.Id, AJob.DryRun, AJob.DryRunSpecified,
      lTarget, AJob.Options, lFindings, lSummary, lResult, lFailure);
    if (AJob.Findings.Count + lFindings.Count > xeAutomationMaxJobFindings) or
       (TEncoding.UTF8.GetByteCount(AJob.Findings.ToJSON(False)) +
        TEncoding.UTF8.GetByteCount(lFindings.ToJSON(False)) > xeAutomationMaxJobFindingBytes) then
      raise xeAutomationNewError('job_capacity', 'Job findings exceed the retained result budget');
    xeAutomationMergeJobObject(AJob.SummaryData, lSummary);
    xeAutomationMergeJobObject(AJob.ResultData, lResult);
    for i := 0 to lFindings.Count - 1 do
      xeAutomationAddFindingCopy(AJob.Findings, lFindings, i);
    if lFailure.Count > 0 then
      AJob.FailureData.Assign(lFailure)
    else
      Inc(AJob.WorkIndex);
  finally
    lFindings.Free;
    lFailure.Free;
    lResult.Free;
    lSummary.Free;
    lTarget.Free;
  end;
end;

procedure xeAutomationPruneTerminalJobs;
var
  lTerminalCount: Integer;
  i: Integer;
  lJob: TxeAutomationJob;
begin
  lTerminalCount := 0;
  for lJob in xeAutomationGetJobs do
    if lJob.IsTerminal then
      Inc(lTerminalCount);

  i := 0;
  while (lTerminalCount > xeAutomationTerminalJobRetention) and (i < xeAutomationGetJobs.Count) do begin
    lJob := xeAutomationGetJobs[i];
    if lJob.IsTerminal and (lJob <> xeAutomationActiveJob) then begin
      xeAutomationGetJobs.Delete(i);
      Dec(lTerminalCount);
      Continue;
    end;
    Inc(i);
  end;
end;

procedure xeAutomationFinishActiveJobIfTerminal(const AJob: TxeAutomationJob);
begin
  if (AJob = xeAutomationActiveJob) and AJob.IsTerminal then begin
    // The retained result must not pin plugin interfaces after the plan ends.
    AJob.StartMutation.Files := nil;
    xeAutomationActiveJob := nil;
    xeAutomationPruneTerminalJobs;
  end;
end;

procedure xeAutomationPreflightJobTargets(const AJob: TxeAutomationJob);
var
  lFile: IwbFile;
  i: Integer;
begin
  if AJob.DryRun or
     not ((Copy(AJob.Kind, 1, 9) = 'cleaning.') or
          (AJob.Kind = 'files.hygiene.batch') or
          (AJob.Kind = 'plugin.formids.compact_for_esl') or
          (AJob.Kind = 'plugin.esl.apply')) then
    Exit;
  // Reject a protected later target before the first file can be changed.
  for i := 0 to AJob.TotalWork - 1 do begin
    lFile := xeAutomationRequirePluginFile(Trim(AJob.Target.A['files'].S[i]));
    if Copy(AJob.Kind, 1, 7) = 'plugin.' then
      xeAutomationRequireWritableEslMutationTarget(lFile)
    else
      xeAutomationRequireWritableTargetFile(lFile);
  end;
end;

procedure xeAutomationAdvanceJob(const AJob: TxeAutomationJob);
var
  lRegistration: TxeAutomationJobKindRegistration;
  lSnapshot: TxeAutomationMutationSnapshot;
begin
  if not Assigned(AJob) or AJob.IsTerminal then
    Exit;

  // Jobs are deliberately poll-driven from jobs.get instead of using a worker
  // thread; xEdit's loaded plugin graph is UI/main-thread state and many native
  // operations assume that thread-safety boundary.
  if AJob.State = xajsCancelRequested then begin
    AJob.State := xajsCanceled;
    xeAutomationFinishActiveJobIfTerminal(AJob);
    Exit;
  end;

  if not (AJob.State in [xajsQueued, xajsRunning]) then
    Exit;

  lSnapshot := AJob.StartMutation;
  AJob.State := xajsRunning;
  try
    if (wbGlobalModifedGeneration <> AJob.ExpectedRevision) or
       (xeAutomationQuerySemanticRevision <> AJob.ExpectedSemanticRevision) then
      raise xeAutomationNewError('job_state_changed', 'Loaded graph changed outside this job; restart planning');
    if not AJob.PreflightDone then begin
      xeAutomationPreflightJobTargets(AJob);
      AJob.PreflightDone := True;
    end;
    if not xeAutomationGetJobKinds.TryGetValue(AJob.Kind, lRegistration) then
      raise xeAutomationNewError(xeAutomationErrorUnknownJobKind, Format('Automation job kind not registered: %s', [AJob.Kind]));
    // One registered work unit per poll is the safe yield point. Legacy kinds
    // use files; LOD uses worlds. A native unit runs on the main thread.
    xeAutomationRunNextFile(AJob, lRegistration);
    AJob.ExpectedRevision := wbGlobalModifedGeneration;
    AJob.ExpectedSemanticRevision := xeAutomationQuerySemanticRevision;
    if AJob.State = xajsCancelRequested then
      AJob.State := xajsCanceled
    else if AJob.FailureData.Count > 0 then begin
      AJob.State := xajsFailed;
      if AJob.WorkKey = 'files' then AJob.FailureData.I['completedFiles'] := AJob.WorkIndex
      else if AJob.WorkKey = 'worldspaces' then AJob.FailureData.I['completedWorldspaces'] := AJob.WorkIndex
      else AJob.FailureData.I['completedSteps'] := AJob.WorkIndex;
      xeAutomationWriteMutationAudit(AJob.FailureData.O['mutationState'], lSnapshot);
      if AJob.FailureData.O['mutationState'].B['mutationsObserved'] then begin
        AJob.FailureData.B['partial'] := True;
        AJob.FailureData.B['partialKnown'] := True;
      end else begin
        AJob.FailureData['partial'] := nil;
        AJob.FailureData.B['partialKnown'] := False;
      end;
    end
    else if AJob.WorkIndex >= AJob.TotalWork then
      AJob.State := xajsSucceeded;
  except
    on E: ExeAutomationError do begin
      // Accepted jobs report execution failures in durable job state instead of
      // turning a later poll into a transport-level error envelope.
      if Assigned(E.Details) then
        AJob.FailureData.O['details'].Assign(E.Details);
      AJob.FailureData.S['code'] := E.Code;
      AJob.FailureData.S['message'] := E.Message;
      AJob.FailureData.S['phase'] := 'execution';
      if AJob.WorkKey = 'files' then AJob.FailureData.I['completedFiles'] := AJob.WorkIndex
      else if AJob.WorkKey = 'worldspaces' then AJob.FailureData.I['completedWorldspaces'] := AJob.WorkIndex
      else AJob.FailureData.I['completedSteps'] := AJob.WorkIndex;
      xeAutomationWriteMutationAudit(AJob.FailureData.O['mutationState'], lSnapshot);
      if AJob.FailureData.O['mutationState'].B['mutationsObserved'] then begin
        AJob.FailureData.B['partial'] := True;
        AJob.FailureData.B['partialKnown'] := True;
      end else begin
        // Generic exceptions cannot establish absence of external-file writes.
        AJob.FailureData['partial'] := nil;
        AJob.FailureData.B['partialKnown'] := False;
      end;
      AJob.State := xajsFailed;
    end;
    on E: Exception do begin
      AJob.FailureData.S['code'] := xeAutomationErrorInternalError;
      AJob.FailureData.S['message'] := E.Message;
      AJob.FailureData.S['phase'] := 'execution';
      if AJob.WorkKey = 'files' then AJob.FailureData.I['completedFiles'] := AJob.WorkIndex
      else if AJob.WorkKey = 'worldspaces' then AJob.FailureData.I['completedWorldspaces'] := AJob.WorkIndex
      else AJob.FailureData.I['completedSteps'] := AJob.WorkIndex;
      xeAutomationWriteMutationAudit(AJob.FailureData.O['mutationState'], lSnapshot);
      if AJob.FailureData.O['mutationState'].B['mutationsObserved'] then begin
        AJob.FailureData.B['partial'] := True;
        AJob.FailureData.B['partialKnown'] := True;
      end else begin
        // Generic exceptions cannot establish absence of external-file writes.
        AJob.FailureData['partial'] := nil;
        AJob.FailureData.B['partialKnown'] := False;
      end;
      AJob.State := xajsFailed;
    end;
  end;

  xeAutomationFinishActiveJobIfTerminal(AJob);
end;

function xeAutomationStartJob(const AKind: string; const ADryRun, ADryRunSpecified: Boolean; const ATarget, AOptions: TJsonObject): TJsonObject;
var
  lKind: string;
  lJob: TxeAutomationJob;
  lDryRun: Boolean;
  lRegistration: TxeAutomationJobKindRegistration;
begin
  lKind := xeAutomationNormalizeJobKind(AKind);
  if not xeAutomationGetJobKinds.TryGetValue(lKind, lRegistration) then
    // Unknown-kind validation intentionally runs before the active-job check so
    // malformed or unsupported requests get a stable shape even during long work.
    raise xeAutomationNewError(xeAutomationErrorUnknownJobKind, Format('Automation job kind not registered: %s', [AKind]));

  lDryRun := ADryRun;
  // Kind-specific start validators run after known-kind lookup but before active
  // job conflict checks so schema errors remain deterministic during queued work.
  if Assigned(lRegistration.Validator) then
    lRegistration.Validator(lDryRun, ADryRunSpecified, ATarget, AOptions);

  if Assigned(xeAutomationActiveJob) and not xeAutomationActiveJob.IsTerminal then
    raise xeAutomationNewError(xeAutomationErrorJobBusy, Format('Automation job already active: %s', [xeAutomationActiveJob.Id]));

  Inc(xeAutomationNextJobId);
  Inc(xeAutomationNextJobSequence);
  lJob := TxeAutomationJob.Create;
  try
    lJob.Id := Format('job-%.6d', [xeAutomationNextJobId]);
    lJob.Kind := lKind;
    lJob.State := xajsQueued;
    lJob.Sequence := xeAutomationNextJobSequence;
    lJob.DryRun := lDryRun;
    lJob.DryRunSpecified := ADryRunSpecified;
    xeAutomationCopyJsonObject(ATarget, lJob.Target);
    xeAutomationCopyJsonObject(AOptions, lJob.Options);
    lJob.WorkKey := lRegistration.WorkKey;
    lJob.TotalWork := lJob.Target.A[lJob.WorkKey].Count;
    lJob.StartMutation := xeAutomationCaptureMutationSnapshot;
    lJob.ExpectedRevision := lJob.StartMutation.Generation;
    lJob.ExpectedSemanticRevision := xeAutomationQuerySemanticRevision;

    xeAutomationGetJobs.Add(lJob);
    xeAutomationActiveJob := lJob;
    lJob := nil;
    Result := xeAutomationNewJobSnapshot(xeAutomationActiveJob);
  finally
    lJob.Free;
  end;
end;

function xeAutomationGetJob(const AJobId: string): TJsonObject;
var
  lJob: TxeAutomationJob;
begin
  lJob := xeAutomationRequireJob(AJobId);
  xeAutomationAdvanceJob(lJob);
  Result := xeAutomationNewJobSnapshot(lJob);
end;

function xeAutomationGetJobFindings(const AJobId: string; const AOffset, ALimit: Integer): TJsonObject;
var
  lJob: TxeAutomationJob;
  i: Integer;
  lEnd: Integer;
begin
  lJob := xeAutomationRequireJob(AJobId);
  Result := TJsonObject.Create;
  xeAutomationWriteFindingJobFields(Result, lJob);
  Result.I['offset'] := AOffset;
  Result.I['limit'] := ALimit;
  Result.I['total'] := lJob.Findings.Count;
  // Initialize before paging so empty result pages still serialize the stable
  // protocol shape with findings: [] instead of omitting the field entirely.
  Result.A['findings'].Clear;
  lEnd := AOffset + ALimit;
  if lEnd > lJob.Findings.Count then
    lEnd := lJob.Findings.Count;
  for i := AOffset to Pred(lEnd) do
    // Findings are copied in stored order so completed jobs keep stable paging
    // even after newer terminal jobs are retained beside them.
    xeAutomationAddFindingCopy(Result.A['findings'], lJob.Findings, i);
end;

function xeAutomationCancelJob(const AJobId: string): TJsonObject;
var
  lJob: TxeAutomationJob;
begin
  lJob := xeAutomationRequireJob(AJobId);
  if lJob.IsTerminal then
    Exit(xeAutomationNewJobSnapshot(lJob));

  if lJob.State in [xajsQueued, xajsRunning] then begin
    lJob.State := xajsCancelRequested;
    if lJob.WorkIndex > 0 then begin
      xeAutomationWriteMutationAudit(lJob.FailureData.O['mutationState'], lJob.StartMutation);
      lJob.SummaryData.B['partialChanges'] := lJob.FailureData.O['mutationState'].B['mutationsObserved'] or
        lJob.SummaryData.B['externalOutputWritten'];
    end;
    xeAutomationAdvanceJob(lJob);
  end else
    raise xeAutomationNewError(xeAutomationErrorOperationNotCancelable, Format('Automation job is not cancelable: %s', [AJobId]));

  Result := xeAutomationNewJobSnapshot(lJob);
end;

function xeAutomationDiscardJob(const AJobId: string): TJsonObject;
var
  lJob: TxeAutomationJob;
begin
  lJob := xeAutomationRequireJob(AJobId);
  if not lJob.IsTerminal then
    raise xeAutomationNewError(xeAutomationErrorJobNotTerminal, Format('Automation job is not terminal: %s', [AJobId]));

  Result := xeAutomationNewJobSnapshot(lJob);
  if lJob = xeAutomationActiveJob then
    xeAutomationActiveJob := nil;
  xeAutomationGetJobs.Remove(lJob);
end;

initialization
finalization
  xeAutomationActiveJob := nil;
  FreeAndNil(xeAutomationJobList);
  FreeAndNil(xeAutomationJobKinds);
end.
