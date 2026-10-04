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
uses SysUtils, Classes, JsonDataObjects, wbInterface, wbImplementation,
  wbLoadOrder, xeMainForm, xeAutomationJobs, xeAutomationErrors,
  xeAutomationDataLookup, xeAutomationObjectModel, xeAutomationRecordQueries;

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
  ASummary.S['cancelBoundary'] := 'between stages/files; incomplete flags unavailable';
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

procedure xeAutomationRegisterReachabilityJobs;
begin
  xeAutomationRegisterJobKindWithValidator('analysis.reachability', xeReachRun, xeReachValidate, 'steps');
end;
end.
