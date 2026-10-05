{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationCommandsReachability;

interface
procedure xeAutomationRegisterReachabilityJobs;
function xeAutomationReachabilityIsCurrent: Boolean;

implementation
uses SysUtils, Classes, System.Diagnostics, JsonDataObjects, wbInterface, wbImplementation,
  wbLoadOrder, xeMainForm, xeAutomationJobs, xeAutomationErrors,
  xeAutomationDataLookup, xeAutomationObjectModel, xeAutomationRecordQueries,
  xeAutomationRegistry;

var ReachabilityComplete: Boolean;
    ReachabilityGeneration, ReachabilitySemanticRevision: UInt64;

function xeAutomationReachabilityIsCurrent: Boolean;
begin
  Result := ReachabilityComplete and (ReachabilityGeneration = wbGlobalModifedGeneration) and
    (ReachabilitySemanticRevision = xeAutomationQuerySemanticRevision);
end;

procedure xeReachStep(const ASteps: TJsonArray; const APhase, AFile: string);
var lStep: TJsonObject;
begin
  lStep := ASteps.AddObject;
  lStep.S['phase'] := APhase;
  if AFile <> '' then lStep.S['file'] := AFile;
end;

procedure xeReachValidate(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
var
  lModules: TwbModuleInfos;
  lFile: IwbFile;
  lLocator: TxeAutomationLocator;
  lRoot: IwbMainRecord;
  lSeen: TStringList;
  i, j, lLoadedCount, lReportCount: Integer;
begin
  if not ADryRunSpecified then ADryRun := True;
  if wbGameMode = gmTES3 then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Reachability requires TES4-style record identities');
  if not Assigned(ATarget) or not ATarget.Contains('files') or
     (ATarget.Types['files'] <> jdtArray) or (ATarget.A['files'].Count < 1) or
     (ATarget.A['files'].Count > 32) then
    raise xeAutomationInvalidRequest('target.files must contain 1..32 report-scope plugin names');
  if ATarget.Contains('steps') then raise xeAutomationInvalidRequest('target.steps is reserved for the staged native plan');
  if ATarget.Contains('roots') and (ATarget.Types['roots'] <> jdtArray) then
    raise xeAutomationInvalidRequest('target.roots must be an array of additional root locators');
  if ATarget.A['roots'].Count > 32 then raise xeAutomationInvalidRequest('At most 32 additional roots are supported');
  for i := 0 to ATarget.A['roots'].Count - 1 do begin
    if ATarget.A['roots'].Types[i] <> jdtObject then raise xeAutomationInvalidRequest('Roots must be locator objects');
    lLocator := xeAutomationParseLocator(ATarget.A['roots'].O[i], True, False);
    if lLocator.Path <> '' then raise xeAutomationInvalidRequest('Reachability roots must be record roots');
    lRoot := xeAutomationRequireMainRecord(lLocator);
    if lRoot.WinningOverride.IsDeleted then raise xeAutomationInvalidTarget('Additional root has a deleted winner');
  end;
  lSeen := TStringList.Create;
  try
    lReportCount := 0;
    for i := 0 to ATarget.A['files'].Count - 1 do begin
      if ATarget.A['files'].Types[i] <> jdtString then raise xeAutomationInvalidRequest('Report file names must be strings');
      lFile := xeAutomationRequirePluginFile(ATarget.A['files'].S[i]);
      if lSeen.IndexOf(LowerCase(lFile.FileName)) >= 0 then raise xeAutomationInvalidRequest('Duplicate report file');
      lSeen.Add(LowerCase(lFile.FileName));
      Inc(lReportCount, lFile.RecordCount);
    end;
    if lReportCount > 1000 then raise xeAutomationNewError('job_capacity', 'Report scope exceeds 1000 records; narrow target.files');
  finally lSeen.Free; end;
  lModules := wbModulesByLoadOrder.FilteredByFlag(mfHasFile);
  if Length(lModules) > 256 then raise xeAutomationNewError('job_capacity', 'Loaded graph exceeds 256 files');
  lLoadedCount := 0;
  for i := Low(lModules) to High(lModules) do begin
    lFile := lModules[i]._File;
    if Assigned(lFile) then Inc(lLoadedCount, lFile.RecordCount);
  end;
  if lLoadedCount > 1000000 then raise xeAutomationNewError('job_capacity', 'Loaded reachability graph exceeds 1000000 records');
  // Analysis is global: reset all files before propagating from any native root.
  // target.files limits readback, never the graph traversal or native root set.
  for j := 0 to 2 do
    for i := Low(lModules) to High(lModules) do begin
      lFile := lModules[i]._File;
      if not Assigned(lFile) then Continue;
      case j of
        0: xeReachStep(ATarget.A['steps'], 'references', lFile.FileName);
        1: xeReachStep(ATarget.A['steps'], 'reset', lFile.FileName);
        2: xeReachStep(ATarget.A['steps'], 'native-roots', lFile.FileName);
      end;
    end;
  xeReachStep(ATarget.A['steps'], 'additional-roots', '');
  for i := 0 to ATarget.A['files'].Count - 1 do
    xeReachStep(ATarget.A['steps'], 'report', ATarget.A['files'].S[i]);
  xeReachStep(ATarget.A['steps'], 'complete', '');
end;

procedure xeReachProgress(const AStatus: string);
begin
  // Poll-driven work must not forward wbTick into GUI message pumping.
end;

procedure xeReachRun(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray;
  const ASummary, AResult, AFailure: TJsonObject);
var
  lStep, lRow: TJsonObject;
  lFile: IwbFile;
  lModule: PwbModuleInfo;
  lRecord: IwbMainRecord;
  lPreviousBudget: Integer;
  lPreviousCacheSave: Boolean;
  lPreviousProgress: TwbProgressCallback;
  i: Integer;
begin
  lStep := ATarget.A['steps'].O[0];
  ASummary.S['scope'] := 'entire-loaded-plugin-graph; target.files limits report only';
  ASummary.S['roots'] := 'native-game-roots plus optional target.roots';
  ASummary.S['persistence'] := 'derived-memory-state only; no plugin save required';
  ASummary.S['cancelBoundary'] := 'between reference/reset/report actions and additional roots; native root-file stages/root propagations indivisible';
  lRow := AResult.A['steps'].AddObject;
  lRow.Assign(lStep);
  if ADryRun then begin lRow.S['outcome'] := 'planned'; Exit; end;
  ReachabilityComplete := False;
  // A failed/canceled pass never advertises the half-built GUI filter flags.
  if Assigned(frmMain) then frmMain.AutomationSetReachableBuilt(False);
  lPreviousBudget := wbAutomationReachabilityBudget;
  wbAutomationReachabilityBudget := 5000000;
  lPreviousCacheSave := wbDontCacheSave;
  wbDontCacheSave := True;
  lPreviousProgress := _wbProgressCallback;
  _wbProgressCallback := xeReachProgress;
  try
    try
      if lStep.S['file'] <> '' then begin
        lModule := wbModuleByName(lStep.S['file']);
        if not Assigned(lModule) or not (mfHasFile in lModule.miFlags) then
          raise xeAutomationStateConflict('Loaded analysis file is unavailable');
        lFile := lModule._File;
      end;
      if lStep.S['phase'] = 'references' then begin
        lFile.BuildRef;
      end else if lStep.S['phase'] = 'reset' then begin
        lFile.ResetReachable;
        xeAutomationInvalidateRecordQueries;
      end else if lStep.S['phase'] = 'native-roots' then begin
        lFile.BuildReachable;
      end else if lStep.S['phase'] = 'additional-roots' then begin
        for i := 0 to ATarget.A['roots'].Count - 1 do begin
          lRecord := xeAutomationRequireMainRecord(xeAutomationParseLocator(ATarget.A['roots'].O[i], True, False)).WinningOverride;
          wbAutomationReachRoot(lRecord);
        end;
      end else if lStep.S['phase'] = 'report' then begin
        for i := 0 to lFile.RecordCount - 1 do begin
          if not Supports(lFile.Records[i], IwbMainRecord, lRecord) then Continue;
          if lRecord.Signature = 'TES4' then Continue;
          with AFindings.AddObject do begin
            S['validity'] := 'historical classification only if containing job succeeds';
            S['file'] := lFile.FileName;
            S['formId'] := lRecord.LoadOrderFormID.ToString(False);
            S['signature'] := string(lRecord.Signature);
            S['editorId'] := Copy(lRecord.EditorID, 1, 128);
            B['reachable'] := lRecord.IsReachable;
            B['notReachable'] := lRecord.IsNotReachable;
            B['deleted'] := lRecord.IsDeleted;
            B['winning'] := lRecord.IsWinningOverride;
          end;
          ASummary.I['reportedRecords'] := ASummary.I['reportedRecords'] + 1;
          if lRecord.IsReachable then ASummary.I['reachableRecords'] := ASummary.I['reachableRecords'] + 1;
          if lRecord.IsNotReachable then ASummary.I['notReachableRecords'] := ASummary.I['notReachableRecords'] + 1;
        end;
      end else if lStep.S['phase'] = 'complete' then begin
        ReachabilityComplete := True;
        ReachabilityGeneration := wbGlobalModifedGeneration;
        ReachabilitySemanticRevision := xeAutomationQuerySemanticRevision;
        if Assigned(frmMain) then frmMain.AutomationSetReachableBuilt(True);
        ASummary.B['analysisComplete'] := True;
        AResult.S['readbackValidity'] := 'terminal succeeded snapshot only; rerun after graph edits';
      end;
      lRow.S['outcome'] := 'completed';
    except
      on E: Exception do begin
        lRow.S['outcome'] := 'failed';
        AFailure.S['code'] := 'reachability_failed';
        AFailure.S['message'] := E.Message;
        AFailure.S['phase'] := lStep.S['phase'];
        AFailure.B['derivedFlagsUnavailable'] := True;
      end;
    end;
  finally
    _wbProgressCallback := lPreviousProgress;
    wbDontCacheSave := lPreviousCacheSave;
    wbAutomationReachabilityBudget := lPreviousBudget;
  end;
end;

function xeReferenceStatus(const Args: TJsonObject): TJsonObject;
var Module: PwbModuleInfo; FileRef: IwbFile; Row: TJsonObject; Current: Boolean;
begin
  Result := TJsonObject.Create;
  Result.B['allLoadedCurrent'] := True;
  Result.S['mutationRevision'] := UIntToStr(wbGlobalModifedGeneration);
  Result.S['indexRevision'] := UIntToStr(xeAutomationQuerySemanticRevision);
  Result.S['validity'] := 'current snapshot only; rebuild after graph changes';
  for Module in wbModulesByLoadOrder do begin
    if not (mfHasFile in Module.miFlags) then Continue;
    FileRef := Module._File;
    if not Assigned(FileRef) then Continue;
    Current := wbAutomationReferenceIndexIsCurrent(FileRef);
    Row := Result.A['files'].AddObject;
    Row.S['file'] := FileRef.FileName; Row.B['current'] := Current;
    Row.S['generation'] := IntToStr(FileRef.ElementGeneration);
    Result.B['allLoadedCurrent'] := Result.B['allLoadedCurrent'] and Current;
  end;
  Result.I['loadedFiles'] := Result.A['files'].Count;
end;

procedure xeReferenceValidate(var Dry: Boolean; const Specified: Boolean;
  const Target, Options: TJsonObject);
var AllLoaded, Present: Boolean; Files: TxeAutomationFiles; Module: PwbModuleInfo;
  FileRef: IwbFile; i, j: Integer;
begin
  if not Specified then Dry := True;
  if wbIsMorrowind then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Reference-index jobs require numeric record definitions');
  for i := 0 to Target.Count - 1 do
    if not SameText(Target.Names[i], 'files') and not SameText(Target.Names[i], 'allLoaded') then
      raise xeAutomationInvalidRequest('Reference target accepts only files or allLoaded');
  if Assigned(Options) and (Options.Count > 0) then
    raise xeAutomationInvalidRequest('Reference indexing does not accept options');
  if Target.Contains('steps') then raise xeAutomationInvalidRequest('target.steps is reserved for the native plan');
  AllLoaded := xeAutomationReadBooleanArg(Target, 'allLoaded', Present);
  if AllLoaded then begin
    if Target.Contains('files') then raise xeAutomationInvalidRequest('Choose allLoaded:true or explicit files');
    for Module in wbModulesByLoadOrder do begin
      if not (mfHasFile in Module.miFlags) then Continue;
      FileRef := Module._File;
      if Assigned(FileRef) then xeReachStep(Target.A['steps'], 'references', FileRef.FileName);
    end;
  end else begin
    Files := xeAutomationRequirePluginFiles(xeAutomationReadStringArrayArg(Target, 'files'));
    if (Length(Files) < 1) or (Length(Files) > 32) then raise xeAutomationInvalidRequest('target.files must contain 1..32 loaded plugin names');
    for i := Low(Files) to High(Files) do begin
      for j := Low(Files) to Pred(i) do
        if Files[i].Equals(Files[j]) then raise xeAutomationInvalidRequest('Duplicate reference file');
      xeReachStep(Target.A['steps'], 'references', Files[i].FileName);
    end;
  end;
  if (Target.A['steps'].Count < 1) or (Target.A['steps'].Count > 256) then
    raise xeAutomationInvalidRequest('Reference plan must contain 1..256 loaded files');
  {$IFDEF USE_PARALLEL_BUILD_REFS}
  if wbBuildingRefsParallel then raise xeAutomationStateConflict('Parallel reference indexing is still active');
  {$ENDIF}
  xeReachStep(Target.A['steps'], 'complete', '');
end;

procedure xeReferenceRun(const JobID: string; const Dry, Specified: Boolean;
  const Target, Options: TJsonObject; const Findings: TJsonArray;
  const Summary, Output, Failure: TJsonObject);
var Step, Row, Status: TJsonObject; Module: PwbModuleInfo; FileRef: IwbFile;
  PreviousCacheSave: Boolean; PreviousProgress: TwbProgressCallback;
begin
  Step := Target.A['steps'].O[0]; Row := Output.A['steps'].AddObject; Row.Assign(Step);
  Summary.S['persistence'] := 'derived index memory only; cache writes suppressed; plugins unchanged';
  Summary.S['cancelBoundary'] := 'between loaded files; one native BuildRef may block';
  if Dry then begin Row.S['outcome'] := 'planned'; Exit; end;
  PreviousCacheSave := wbDontCacheSave; PreviousProgress := _wbProgressCallback;
  wbDontCacheSave := True; _wbProgressCallback := xeReachProgress;
  try
    try
      if Step.S['phase'] = 'complete' then begin
        Status := xeReferenceStatus(nil);
        try Output.O['status'].Assign(Status); finally Status.Free; end;
        Summary.B['selectedScopeComplete'] := True;
      end else begin
        Module := wbModuleByName(Step.S['file']);
        if not Assigned(Module) or not (mfHasFile in Module.miFlags) then raise xeAutomationStateConflict('Planned loaded file is unavailable');
        FileRef := Module._File;
        // Native BuildRef refreshes stale indexes and leaves current ones alone.
        // It sets csRefsBuild before walking, so check completion generation too.
        Row.B['currentBefore'] := wbAutomationReferenceIndexIsCurrent(FileRef);
        xeAutomationInvalidateRecordQueries;
        FileRef.BuildRef;
        if not wbAutomationReferenceIndexIsCurrent(FileRef) then raise xeAutomationStateConflict('Native reference traversal did not produce a current index');
        Row.B['currentAfter'] := True;
        Summary.I['indexedFiles'] := 1;
      end;
      Row.S['outcome'] := 'completed';
    except on E: Exception do begin
      Row.S['outcome'] := 'failed'; Failure.S['code'] := 'reference_index_failed';
      Failure.S['message'] := E.Message; Failure.S['file'] := Step.S['file'];
      Failure.B['selectedScopeIncomplete'] := True;
    end; end;
  finally _wbProgressCallback := PreviousProgress; wbDontCacheSave := PreviousCacheSave; end;
end;

type
  TReferenceBuildStepper = class(TxeAutomationJobStepper)
  private
    FTarget: TJsonObject;
    FFile: IwbFile;
    FRow: TJsonObject;
    FScan: TwbAutomationReferenceBuildScan;
    FDry, FComplete: Boolean;
    FSteps, FLastWork, FWork, FNativeUnits, FDepth: Integer;
  public
    constructor Create(const dry: Boolean; const target: TJsonObject);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TReferenceBuildStepper.Create(const dry: Boolean; const target: TJsonObject);
begin inherited Create; FDry := dry; FTarget := target.Clone; end;
destructor TReferenceBuildStepper.Destroy;
begin
  if Assigned(FScan) then begin
    FScan.Free;
    xeAutomationInvalidateRecordQueries;
  end;
  FTarget.Free; FFile := nil; inherited;
end;

function TReferenceBuildStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var timer: TStopwatch; oldSave: Boolean; oldProgress: TwbProgressCallback;
begin
  Inc(FSteps); FLastWork := 0;
  if FDry or (FTarget.A['steps'].O[0].S['phase'] = 'complete') then begin
    xeReferenceRun('', FDry, True, FTarget, nil, findings, summary, resultData, failure);
    FRow := resultData.A['steps'].O[resultData.A['steps'].Count - 1];
    FRow.B['complete'] := failure.Count = 0;
    FComplete := failure.Count = 0; FLastWork := 1;
    summary.S['persistence'] := 'derived index memory only; reference-cache streams bypassed; plugins unchanged';
    summary.S['cancelBoundary'] := 'between native container actions and record BuildRef calls';
    Exit(FComplete);
  end;
  oldSave := wbDontCacheSave; oldProgress := _wbProgressCallback;
  wbDontCacheSave := True; _wbProgressCallback := xeReachProgress;
  timer := TStopwatch.StartNew;
  try
    try
      if not Assigned(FRow) then begin
        FFile := xeAutomationRequirePluginFile(FTarget.A['steps'].O[0].S['file']);
        FRow := resultData.A['steps'].AddObject; FRow.Assign(FTarget.A['steps'].O[0]);
        FRow.B['currentBefore'] := wbAutomationReferenceIndexIsCurrent(FFile);
        FRow.B['currentAfter'] := False; FRow.B['complete'] := False; FRow.S['outcome'] := 'in_progress';
        summary.S['persistence'] := 'derived index memory only; reference-cache streams bypassed; plugins unchanged';
        summary.S['cancelBoundary'] := 'between native container actions and record BuildRef calls';
        if not summary.Contains('indexedFiles') then summary.I['indexedFiles'] := 0;
        xeAutomationInvalidateRecordQueries;
        FScan := wbAutomationReferenceBuildScan(FFile);
      end;
      while not FComplete and (FLastWork < xeAutomationJobStepWorkLimit) and
        (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
        Inc(FLastWork);
        FComplete := FScan.Advance;
        FWork := FScan.WorkUnits; FNativeUnits := FScan.NativeUnits; FDepth := FScan.RetainedDepth;
      end;
      if FComplete then begin
        FreeAndNil(FScan);
        // Queries opened during partial construction must not outlive changes
        // to native group ownership or reverse edges made by the completed scan.
        xeAutomationInvalidateRecordQueries;
        if not wbAutomationReferenceIndexIsCurrent(FFile) then begin
          FComplete := False;
          raise xeAutomationStateConflict('Native traversal did not produce a current reference index');
        end;
        FRow.B['currentAfter'] := True; FRow.B['complete'] := True; FRow.S['outcome'] := 'completed';
        summary.I['indexedFiles'] := summary.I['indexedFiles'] + 1;
      end;
    except
      on E: Exception do begin
        if Assigned(FScan) then begin
          FWork := FScan.WorkUnits; FNativeUnits := FScan.NativeUnits; FDepth := FScan.RetainedDepth;
        end;
        if Assigned(FRow) then FRow.S['outcome'] := 'failed';
        if E is EwbAutomationReferenceScanCapacity then failure.S['code'] := 'job_capacity'
        else if E is EwbAutomationReferenceScanInvalidated then failure.S['code'] := 'job_state_changed'
        else failure.S['code'] := 'reference_index_failed';
        failure.S['message'] := E.Message; failure.S['file'] := FTarget.A['steps'].O[0].S['file'];
        failure.B['selectedScopeIncomplete'] := True;
        FreeAndNil(FScan);
        xeAutomationInvalidateRecordQueries;
      end;
    end;
  finally
    _wbProgressCallback := oldProgress; wbDontCacheSave := oldSave;
    if Assigned(FRow) then begin
      FRow.I['workUnits'] := FWork; FRow.I['nativeUnits'] := FNativeUnits;
      FRow.B['currentAfter'] := wbAutomationReferenceIndexIsCurrent(FFile);
    end;
  end;
  Result := FComplete;
end;

procedure TReferenceBuildStepper.WriteProgress(const progress: TJsonObject);
begin
  progress.S['phase'] := FTarget.A['steps'].O[0].S['phase'];
  progress.S['fileName'] := FTarget.A['steps'].O[0].S['file'];
  progress.I['steps'] := FSteps; progress.I['lastWorkUnits'] := FLastWork;
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit; progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.I['scanWorkUnits'] := FWork; progress.I['scanWorkLimit'] := wbAutomationReferenceScanWorkLimit;
  progress.I['nativeUnits'] := FNativeUnits; progress.I['retainedDepth'] := FDepth;
  progress.I['depthLimit'] := wbAutomationReferenceScanDepthLimit;
  progress.B['stageComplete'] := FComplete;
  progress.B['nativeCallsPreemptible'] := False;
  progress.S['cachePolicy'] := 'native current-index fast path; stale indexes rebuilt without reference-cache streams';
  progress.S['nativeAtoms'] := 'container initialization/access; one native record BuildRef; group owner lookup/linkage; final status';
end;

function NewReferenceBuildStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin Result := TReferenceBuildStepper.Create(dry, target); end;

type
  TReachReadbackStepper = class(TxeAutomationJobStepper)
  private
    FTarget: TJsonObject;
    FReference: TReferenceBuildStepper;
    FReferenceProgress: TJsonObject;
    FReset: TwbAutomationReachabilityResetScan;
    FFile: IwbFile;
    FRow: TJsonObject;
    FDryRun, FComplete: Boolean;
    FPhase, FFileName: string;
    FIndex, FTotal, FLastWork, FSteps, FRemainingBudget, FResetWork, FResetDepth: Integer;
    procedure Initialize(const summary, resultData: TJsonObject);
    procedure ReportOne(const findings: TJsonArray; const summary: TJsonObject);
  public
    constructor Create(const dry: Boolean; const target: TJsonObject);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TReachReadbackStepper.Create(const dry: Boolean; const target: TJsonObject);
begin
  inherited Create;
  FDryRun := dry; FTarget := target.Clone;
  FPhase := FTarget.A['steps'].O[0].S['phase'];
  FFileName := FTarget.A['steps'].O[0].S['file'];
  FRemainingBudget := 5000000;
  FReferenceProgress := TJsonObject.Create;
  if not dry and (FPhase = 'references') then
    FReference := TReferenceBuildStepper.Create(False, target);
end;
destructor TReachReadbackStepper.Destroy;
begin
  FReference.Free; FReferenceProgress.Free;
  if Assigned(FReset) then begin FReset.Free; xeAutomationInvalidateRecordQueries; end;
  FTarget.Free; FFile := nil; inherited;
end;

procedure TReachReadbackStepper.Initialize(const summary, resultData: TJsonObject);
begin
  ReachabilityComplete := False;
  if Assigned(frmMain) then frmMain.AutomationSetReachableBuilt(False);
  summary.S['scope'] := 'entire-loaded-plugin-graph; target.files limits report only';
  summary.S['roots'] := 'native-game-roots plus optional target.roots';
  summary.S['persistence'] := 'derived-memory-state only; no plugin save required';
  summary.S['cancelBoundary'] := 'between reference/reset/report actions and additional roots; native root-file stages/root propagations indivisible';
  if FPhase = 'report' then begin
    FFile := xeAutomationRequirePluginFile(FFileName);
    FTotal := FFile.RecordCount;
  end else if FPhase = 'reset' then FTotal := 0 // Total live initialized elements is not materialized.
  else FTotal := FTarget.A['roots'].Count;
  FRow := resultData.A['steps'].AddObject;
  FRow.Assign(FTarget.A['steps'].O[0]);
  FRow.S['outcome'] := 'running'; FRow.B['complete'] := False;
  FRow.I['processed'] := 0; FRow.I['total'] := FTotal;
end;

procedure TReachReadbackStepper.ReportOne(const findings: TJsonArray; const summary: TJsonObject);
var recordRef: IwbMainRecord; finding: TJsonObject;
begin
  if Supports(FFile.Records[FIndex], IwbMainRecord, recordRef) and (recordRef.Signature <> 'TES4') then begin
    finding := TJsonObject.Create;
    try
      finding.S['validity'] := 'historical classification only if containing job succeeds';
      finding.S['file'] := FFile.FileName;
      finding.S['formId'] := recordRef.LoadOrderFormID.ToString(False);
      finding.S['signature'] := string(recordRef.Signature);
      finding.S['editorId'] := Copy(recordRef.EditorID, 1, 128);
      finding.B['reachable'] := recordRef.IsReachable;
      finding.B['notReachable'] := recordRef.IsNotReachable;
      finding.B['deleted'] := recordRef.IsDeleted;
      finding.B['winning'] := recordRef.IsWinningOverride;
      xeAutomationAppendJobFinding(findings, finding);
      finding := nil;
      summary.I['reportedRecords'] := summary.I['reportedRecords'] + 1;
      if recordRef.IsReachable then summary.I['reachableRecords'] := summary.I['reachableRecords'] + 1;
      if recordRef.IsNotReachable then summary.I['notReachableRecords'] := summary.I['notReachableRecords'] + 1;
    finally finding.Free; end;
  end;
  Inc(FIndex);
end;

function TReachReadbackStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var timer: TStopwatch; previousBudget: Integer; previousCacheSave: Boolean;
    previousProgress: TwbProgressCallback; recordRef: IwbMainRecord;
begin
  Inc(FSteps); FLastWork := 0;
  if Assigned(FReference) then begin
    ReachabilityComplete := False;
    if Assigned(frmMain) then frmMain.AutomationSetReachableBuilt(False);
    try
      FComplete := FReference.Advance(findings, summary, resultData, failure);
    finally
      FReference.WriteProgress(FReferenceProgress);
      FLastWork := FReferenceProgress.I['lastWorkUnits'];
      summary.S['scope'] := 'entire-loaded-plugin-graph; target.files limits report only';
      summary.S['roots'] := 'native-game-roots plus optional target.roots';
      summary.S['persistence'] := 'derived-memory-state only; no plugin save required';
      summary.S['cancelBoundary'] := 'between reference/reset/report actions and additional roots; native root-file stages/root propagations indivisible';
      if failure.Count > 0 then failure.B['derivedFlagsUnavailable'] := True;
    end;
    Exit(FComplete);
  end;
  if FDryRun or ((FPhase <> 'report') and (FPhase <> 'additional-roots') and (FPhase <> 'reset')) then begin
    // Existing native stage scope/flags/cache restoration remains authoritative.
    FLastWork := 1;
    xeReachRun('', FDryRun, True, FTarget, nil, findings, summary, resultData, failure);
    FComplete := failure.Count = 0;
    Exit(FComplete);
  end;
  previousBudget := wbAutomationReachabilityBudget;
  previousCacheSave := wbDontCacheSave;
  previousProgress := _wbProgressCallback;
  wbAutomationReachabilityBudget := FRemainingBudget;
  wbDontCacheSave := True; _wbProgressCallback := xeReachProgress;
  timer := TStopwatch.StartNew;
  try
    try
      if not Assigned(FRow) then begin
        Initialize(summary, resultData);
        if FPhase = 'reset' then begin
          FFile := xeAutomationRequirePluginFile(FFileName);
          xeAutomationInvalidateRecordQueries;
          FReset := wbAutomationReachabilityResetScan(FFile);
        end;
      end;
      if FPhase = 'reset' then begin
        while (FLastWork < xeAutomationJobStepWorkLimit) and
          (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
          Inc(FLastWork);
          FComplete := FReset.Advance;
          FResetWork := FReset.WorkUnits; FResetDepth := FReset.RetainedDepth;
          if FComplete then Break;
        end;
        FRow.I['workUnits'] := FResetWork; FRow.B['complete'] := FComplete;
        if FComplete then begin
          FRow.S['outcome'] := 'completed'; FreeAndNil(FReset);
          xeAutomationInvalidateRecordQueries;
        end;
        Exit(FComplete);
      end;
      while (FIndex < FTotal) and (FLastWork < xeAutomationJobStepWorkLimit) and
            (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
        Inc(FLastWork);
        if FPhase = 'report' then ReportOne(findings, summary)
        else begin
          recordRef := xeAutomationRequireMainRecord(xeAutomationParseLocator(FTarget.A['roots'].O[FIndex], True, False)).WinningOverride;
          wbAutomationReachRoot(recordRef);
          Inc(FIndex);
          Break; // One indivisible native graph propagation per poll.
        end;
      end;
      FComplete := FIndex = FTotal;
      FRow.I['processed'] := FIndex;
      FRow.B['complete'] := FComplete;
      if FComplete then FRow.S['outcome'] := 'completed';
    except
      on E: Exception do begin
        FComplete := False;
        if Assigned(FRow) then begin FRow.S['outcome'] := 'failed'; FRow.B['complete'] := False; FRow.I['processed'] := FIndex; end;
        if E is EwbAutomationReachabilityResetCapacity then failure.S['code'] := 'job_capacity'
        else if E is EwbAutomationReachabilityResetInvalidated then failure.S['code'] := 'job_state_changed'
        else if E is ExeAutomationError then failure.S['code'] := ExeAutomationError(E).Code
        else failure.S['code'] := 'reachability_failed';
        failure.S['message'] := Copy(E.Message, 1, 4096);
        failure.S['phase'] := FPhase;
        failure.B['derivedFlagsUnavailable'] := True;
        if Assigned(FReset) then begin
          FResetWork := FReset.WorkUnits; FResetDepth := FReset.RetainedDepth;
          if Assigned(FRow) then FRow.I['workUnits'] := FResetWork;
          FreeAndNil(FReset); xeAutomationInvalidateRecordQueries;
        end;
      end;
    end;
  finally
    summary.I['findings'] := findings.Count;
    FRemainingBudget := wbAutomationReachabilityBudget;
    _wbProgressCallback := previousProgress; wbDontCacheSave := previousCacheSave;
    wbAutomationReachabilityBudget := previousBudget;
  end;
  Result := FComplete and (failure.Count = 0);
end;

procedure TReachReadbackStepper.WriteProgress(const progress: TJsonObject);
begin
  progress.S['phase'] := FPhase; progress.S['fileName'] := FFileName;
  progress.I['processed'] := FIndex; progress.I['total'] := FTotal;
  progress.I['steps'] := FSteps; progress.I['lastWorkUnits'] := FLastWork;
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.I['remainingNativeVisitBudget'] := FRemainingBudget;
  progress.B['stageComplete'] := FComplete;
  progress.B['nativeCallsPreemptible'] := False;
  if FReferenceProgress.Count > 0 then progress.O['referenceCursor'].Assign(FReferenceProgress);
  if FPhase = 'reset' then begin
    progress.I['resetWorkUnits'] := FResetWork; progress.I['resetWorkLimit'] := wbAutomationReachabilityResetWorkLimit;
    progress.I['retainedDepth'] := FResetDepth; progress.I['depthLimit'] := wbAutomationReachabilityResetDepthLimit;
  end;
  progress.S['cooperativePhases'] := 'references/reset/report/additional-roots; native root-file discovery and each root propagation remain atoms';
end;

function NewReachReadbackStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin Result := TReachReadbackStepper.Create(dry, target); end;

procedure xeAutomationRegisterReachabilityJobs;
begin
  xeAutomationRegisterJobKindWithValidator('analysis.reachability', xeReachRun, xeReachValidate, 'steps');
  xeAutomationRegisterJobStepper('analysis.reachability', NewReachReadbackStepper);
  xeAutomationRegisterJobKindWithValidator('analysis.build_references', xeReferenceRun, xeReferenceValidate, 'steps');
  xeAutomationRegisterJobStepper('analysis.build_references', NewReferenceBuildStepper);
  xeAutomationRegisterCommand('analysis.reference_status', xeReferenceStatus);
end;
end.
