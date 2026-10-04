{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsValidation;

interface

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
  wbLoadOrder,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationJobs,
  xeAutomationObjectModel;

const
  xeAutomationValidationCheckForErrorsKind = 'validation.check_for_errors';
  xeAutomationValidationCheckForItmKind = 'validation.check_for_itm';
  xeAutomationValidationCheckForDeletedRefsKind = 'validation.check_for_deleted_refs';
  xeAutomationValidationCircularListsKind = 'validation.circular_leveled_lists';

procedure xeAutomationResetCircularCheckTags;
var
  lModules: TwbModuleInfos;
  lFile: IwbFile;
  i: Integer;
begin
  lModules := wbModulesByLoadOrder;
  for i := Low(lModules) to High(lModules) do begin
    lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
    if Assigned(lFile) then
      lFile.ResetTags;
  end;
end;

procedure xeAutomationWriteCircularPath(const ATarget: TJsonArray; const AMessage: string;
  const ATruncated: TJsonObject);
const
  Prefix = 'Circular Leveled List found: ';
var
  lRemaining: string;
  lPart: string;
  lSeparator: Integer;
begin
  lRemaining := Copy(AMessage, Length(Prefix) + 1, MaxInt);
  while lRemaining <> '' do begin
    if ATarget.Count >= 100 then begin
      ATruncated.B['cyclePathTruncated'] := True;
      Break;
    end;
    lSeparator := Pos(' -> ', lRemaining);
    if lSeparator = 0 then begin
      lPart := lRemaining;
      if Length(lPart) > 160 then
        ATruncated.B['cyclePathTruncated'] := True;
      ATarget.Add(Copy(lPart, 1, 160));
      Break;
    end;
    lPart := Copy(lRemaining, 1, lSeparator - 1);
    if Length(lPart) > 160 then
      ATruncated.B['cyclePathTruncated'] := True;
    ATarget.Add(Copy(lPart, 1, 160));
    Delete(lRemaining, 1, lSeparator + 3);
  end;
end;

procedure xeAutomationCircularListsJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
const
  Signatures: array[0..3] of string = ('LVLI', 'LVLC', 'LVLN', 'LVSP');
var
  lFile: IwbFile;
  lGroup: IwbGroupRecord;
  lRecord, lWinning: IwbMainRecord;
  lFinding, lFileResult: TJsonObject;
  lSignature: string;
  lDirtyBefore: Boolean;
  i, j, lChecked, lCycles: Integer;
begin
  if wbGameMode = gmTES3 then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
      'Circular leveled-list checking requires a plugin game with GRUP records');
  ASummary.S['kind'] := xeAutomationValidationCircularListsKind;
  ASummary.B['validationOnly'] := True;
  ASummary.I['fileCount'] := ATarget.A['files'].Count;
  ASummary.I['checkedRecords'] := 0;
  ASummary.I['cycleCount'] := 0;
  ASummary.B['dirtyChanged'] := False;
  AResult.A['files'].Clear;
  for i := 0 to ATarget.A['files'].Count - 1 do begin
    lFile := xeAutomationRequirePluginFile(Trim(ATarget.A['files'].S[i]));
    lDirtyBefore := lFile.Modified;
    lChecked := 0;
    lCycles := 0;
    // Native checker uses transient tags to avoid revisiting graph branches.
    // Reset around each file scan, including error paths, as the GUI does.
    xeAutomationResetCircularCheckTags;
    try
      for lSignature in Signatures do begin
        lGroup := lFile.GroupBySignature[lSignature];
        if not Assigned(lGroup) then
          Continue;
        for j := 0 to Pred(lGroup.ElementCount) do begin
          if not Supports(lGroup.Elements[j], IwbMainRecord, lRecord) then
            Continue;
          lWinning := lRecord.WinningOverride;
          if not Assigned(lWinning) then
            Continue;
          Inc(lChecked);
          try
            wbLeveledListCheckCircular(lWinning, nil);
          except
            on E: Exception do begin
              if Pos('Circular Leveled List found: ', E.Message) <> 1 then
                raise;
              Inc(lCycles);
              lFinding := AFindings.AddObject;
              lFinding.S['source'] := xeAutomationValidationCircularListsKind;
              lFinding.S['severity'] := 'error';
              lFinding.S['code'] := 'circular_leveled_list';
              lFinding.S['message'] := Copy(E.Message, 1, 4096);
              lFinding.O['target'].S['file'] := lWinning._File.FileName;
              lFinding.O['target'].S['formId'] := lWinning.LoadOrderFormID.ToString(False);
              lFinding.O['target'].S['signature'] := lWinning.Signature;
              lFinding.O['target'].S['path'] := '';
              lFinding.O['action'].S['kind'] := 'none';
              xeAutomationWriteCircularPath(lFinding.A['cyclePathNames'], E.Message, lFinding);
            end;
          end;
        end;
      end;
    finally
      xeAutomationResetCircularCheckTags;
    end;
    lFileResult := AResult.A['files'].AddObject;
    lFileResult.S['fileName'] := lFile.FileName;
    lFileResult.I['checkedRecords'] := lChecked;
    lFileResult.I['cycleCount'] := lCycles;
    lFileResult.B['dirtyBefore'] := lDirtyBefore;
    lFileResult.B['dirtyAfter'] := lFile.Modified;
    lFileResult.B['dirtyChanged'] := lDirtyBefore <> lFile.Modified;
    ASummary.I['checkedRecords'] := ASummary.I['checkedRecords'] + lChecked;
    ASummary.I['cycleCount'] := ASummary.I['cycleCount'] + lCycles;
    ASummary.B['dirtyChanged'] := ASummary.B['dirtyChanged'] or lFileResult.B['dirtyChanged'];
  end;
  ASummary.I['findingCount'] := AFindings.Count;
end;

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
end;

end.
