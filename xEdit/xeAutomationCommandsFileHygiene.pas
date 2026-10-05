{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsFileHygiene;

interface

procedure xeAutomationRegisterFileHygieneCommands;

implementation

uses
  Classes,
  SysUtils,
  System.Diagnostics,
  wbImplementation,
  xeAutomationMutationAudit,
  JsonDataObjects,
  wbInterface,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationJobs,
  xeAutomationMutationPolicy,
  xeAutomationObjectModel,
  xeAutomationRegistry;

type
  TxeAutomationHeaderFlags = record
    ESM: Boolean;
    ESL: Boolean;
    Medium: Boolean;
    // Phase 16 (contract 0.21): Localized exposes IwbFile.IsLocalized on the
    // hygiene mutation surface so Starfield / SSE / FO4 authors can toggle the
    // header localization bit through automation instead of the GUI menu.
    Localized: Boolean;
  end;

  TxeAutomationBatchOperation = (xaboSortMasters, xaboCleanMasters);
  TxeAutomationBatchOperations = set of TxeAutomationBatchOperation;

procedure xeAutomationCaptureDirectMasters(const AFile: IwbFile; const AMasters: TStrings);
var
  i: Integer;
begin
  AMasters.Clear;
  for i := 0 to Pred(AFile.MasterCount[True]) do
    AMasters.Add(AFile.Masters[i, True].FileName);
end;

function xeAutomationNewHeaderFlags(const AFile: IwbFile): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.B['esm'] := AFile.IsESM;
  Result.B['esl'] := AFile.IsLight;
  // Phase 16 (contract 0.21): small mirrors esl since both address the same
  // light-slot bit; emitting both lets Starfield-native wrappers read `small`
  // without translating and legacy wrappers keep reading `esl` unchanged.
  Result.B['small'] := AFile.IsLight;
  Result.B['medium'] := AFile.IsMedium;
  Result.B['localized'] := AFile.IsLocalized;
end;

function xeAutomationMasterLoadOrder(const AMaster: IwbFile): Integer;
begin
  Result := -1;
  if Assigned(AMaster) and (AMaster.LoadOrder >= 0) then
    Result := AMaster.LoadOrder;
end;

procedure xeAutomationWriteMasterObjects(const AFile: IwbFile; const ATarget: TJsonArray);
var
  lMaster: IwbFile;
  lMasterObject: TJsonObject;
  i: Integer;
begin
  // Master lists are reported in xEdit's direct-master order with an explicit
  // sentinel for unavailable load order so clients can diff readbacks stably.
  for i := 0 to Pred(AFile.MasterCount[True]) do begin
    lMaster := AFile.Masters[i, True];
    lMasterObject := TJsonObject.Create;
    try
      if Assigned(lMaster) then
        lMasterObject.S['fileName'] := lMaster.FileName
      else
        lMasterObject.S['fileName'] := '';
      lMasterObject.I['index'] := i;
      lMasterObject.I['loadOrder'] := xeAutomationMasterLoadOrder(lMaster);
      ATarget.Add(lMasterObject);
      lMasterObject := nil;
    finally
      lMasterObject.Free;
    end;
  end;
end;

procedure xeAutomationWriteStringList(const ASource: TStrings; const ATarget: TJsonArray);
var
  i: Integer;
begin
  for i := 0 to Pred(ASource.Count) do
    ATarget.Add(ASource[i]);
end;

procedure xeAutomationWriteDirtyFileNames(const AFile: IwbFile; const ATarget: TJsonArray);
begin
  if Assigned(AFile) and AFile.Modified then
    ATarget.Add(AFile.FileName);
end;

procedure xeAutomationAddUniqueString(const ATarget: TJsonArray; const AValue: string);
var
  i: Integer;
begin
  for i := 0 to Pred(ATarget.Count) do
    if SameText(ATarget.S[i], AValue) then
      Exit;
  ATarget.Add(AValue);
end;

function xeAutomationStringListsEqual(const ALeft, ARight: TStrings): Boolean;
var
  i: Integer;
begin
  Result := ALeft.Count = ARight.Count;
  if not Result then
    Exit;

  for i := 0 to Pred(ALeft.Count) do
    if not SameText(ALeft[i], ARight[i]) then
      Exit(False);
end;

procedure xeAutomationWriteRemovedMasters(const ABefore, AAfter: TStrings; const ATarget: TJsonArray);
var
  i: Integer;
begin
  for i := 0 to Pred(ABefore.Count) do
    if AAfter.IndexOf(ABefore[i]) < 0 then
      ATarget.Add(ABefore[i]);
end;

function xeAutomationReadRequestedHeaderFlags(const AArgs: TJsonObject; out AFlags: TxeAutomationHeaderFlags;
  out AHasESM, AHasESL, AHasMedium, AHasLocalized: Boolean): TJsonObject;
var
  lName: string;
  lHasSmallAlias: Boolean;
  lSmallValue: Boolean;
  i: Integer;
begin
  if not Assigned(AArgs) then
    raise xeAutomationInvalidRequest('Automation command args are required');

  if not AArgs.Contains('flags') then
    raise xeAutomationInvalidRequest('Automation arg "flags" is required');
  if AArgs.Types['flags'] <> jdtObject then
    raise xeAutomationInvalidRequest('Automation arg field "flags" must be an object');

  Result := AArgs.O['flags'];
  AHasESM := False;
  AHasESL := False;
  AHasMedium := False;
  AHasLocalized := False;
  lHasSmallAlias := False;
  lSmallValue := False;
  AFlags.ESM := False;
  AFlags.ESL := False;
  AFlags.Medium := False;
  AFlags.Localized := False;
  for i := 0 to Pred(Result.Count) do begin
    lName := Result.Names[i];
    // Header flags are named at the protocol boundary so typos still fail while
    // current xEdit-supported plugin flags, including Starfield medium, remain reachable.
    // Phase 16 (contract 0.21): `small` is a Starfield-native alias of `esl` /
    // light-slot; `localized` maps to IwbFile.IsLocalized. Both stay accepted for
    // all games so wrappers can uniformly toggle them.
    if not SameText(lName, 'esm') and not SameText(lName, 'esl') and
       not SameText(lName, 'small') and not SameText(lName, 'medium') and
       not SameText(lName, 'localized') then
      raise xeAutomationInvalidRequest(Format('Automation files.set_header_flags flag "%s" is not supported', [lName]));
    if Result.Types[lName] <> jdtBool then
      raise xeAutomationInvalidRequest(Format('Automation files.set_header_flags flag "%s" must be a boolean', [lName]));

    if SameText(lName, 'esm') then begin
      AHasESM := True;
      AFlags.ESM := Result.B[lName];
    end else if SameText(lName, 'esl') then begin
      AHasESL := True;
      AFlags.ESL := Result.B[lName];
    end else if SameText(lName, 'small') then begin
      lHasSmallAlias := True;
      lSmallValue := Result.B[lName];
    end else if SameText(lName, 'medium') then begin
      AHasMedium := True;
      AFlags.Medium := Result.B[lName];
    end else if SameText(lName, 'localized') then begin
      AHasLocalized := True;
      AFlags.Localized := Result.B[lName];
    end;
  end;

  // small / esl are aliases; disagreement in the same request is a hard error
  // rather than a silent OR so wrappers that send both by mistake fail loudly.
  if AHasESL and lHasSmallAlias and (AFlags.ESL <> lSmallValue) then
    raise xeAutomationInvalidRequest('Automation files.set_header_flags flags "small" and "esl" are aliases and must not disagree; set only one, or the same boolean on both');
  if lHasSmallAlias and not AHasESL then begin
    AHasESL := True;
    AFlags.ESL := lSmallValue;
  end;
end;

function xeAutomationFileHygieneGetHeader(const AArgs: TJsonObject): TJsonObject;
begin
  Result := xeAutomationNewFileSummary(
    xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'))
  );
end;

function xeAutomationFileHygieneGetMasters(const AArgs: TJsonObject): TJsonObject;
var
  lFile: IwbFile;
begin
  lFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  Result := TJsonObject.Create;
  try
    Result.S['fileName'] := lFile.FileName;
    xeAutomationWriteMasterObjects(lFile, Result.A['masters']);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationFileHygieneSetHeaderFlags(const AArgs: TJsonObject): TJsonObject;
var
  lFile: IwbFile;
  lFlags: TxeAutomationHeaderFlags;
  lHasESM: Boolean;
  lHasESL: Boolean;
  lHasMedium: Boolean;
  lHasLocalized: Boolean;
  lOldESM: Boolean;
  lOldESL: Boolean;
  lOldMedium: Boolean;
  lOldLocalized: Boolean;
  lChanged: Boolean;
  lDeniedReason: string;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then begin
    Result := xeAutomationErrorsBuildConsentRequired('files.set_header_flags', 'files-mutation', lDeniedReason);
    Exit;
  end;

  lFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  xeAutomationReadRequestedHeaderFlags(AArgs, lFlags, lHasESM, lHasESL, lHasMedium, lHasLocalized);
  // File-header mutations share the central protected-target guard so official,
  // hardcoded, game-master, read-only, and no-edit modes fail the same way as
  // existing record/element mutation commands.
  // Request shape is validated first so malformed flags report invalid_request
  // instead of being masked by protected-target policy.
  xeAutomationRequireWritableTargetFile(lFile);

  lOldESM := lFile.IsESM;
  lOldESL := lFile.IsLight;
  lOldMedium := lFile.IsMedium;
  lOldLocalized := lFile.IsLocalized;

  if lHasESM and (lFile.IsESM <> lFlags.ESM) then
    lFile.IsESM := lFlags.ESM;
  if lHasESL and (lFile.IsLight <> lFlags.ESL) then
    lFile.IsLight := lFlags.ESL;
  if lHasMedium and (lFile.IsMedium <> lFlags.Medium) then
    lFile.IsMedium := lFlags.Medium;
  // Phase 16 (contract 0.21): Localized is idempotent and orthogonal to esm/esl/
  // medium slot selection, so it does not need to interact with the light/medium
  // mutually-exclusive setter cascade in IwbMainRecordStructFlags.
  if lHasLocalized and (lFile.IsLocalized <> lFlags.Localized) then
    lFile.IsLocalized := lFlags.Localized;

  lChanged := (lOldESM <> lFile.IsESM) or (lOldESL <> lFile.IsLight) or
              (lOldMedium <> lFile.IsMedium) or (lOldLocalized <> lFile.IsLocalized);

  Result := TJsonObject.Create;
  try
    Result.S['fileName'] := lFile.FileName;
    Result.O['oldFlags'] := xeAutomationNewHeaderFlags(lFile);
    Result.O['oldFlags'].B['esm'] := lOldESM;
    Result.O['oldFlags'].B['esl'] := lOldESL;
    Result.O['oldFlags'].B['small'] := lOldESL;
    Result.O['oldFlags'].B['medium'] := lOldMedium;
    Result.O['oldFlags'].B['localized'] := lOldLocalized;
    Result.O['newFlags'] := xeAutomationNewHeaderFlags(lFile);
    Result.B['changed'] := lChanged;
    // Hygiene commands deliberately dirty only the daemon's in-memory file state;
    // persistence remains the explicit session.save boundary for auditability.
    xeAutomationWriteDirtyFileNames(lFile, Result.A['dirtyFiles']);
    Result.B['requiresSave'] := lFile.Modified;
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationFileHygieneSortMasters(const AArgs: TJsonObject): TJsonObject;
var
  lFile: IwbFile;
  lBefore: TStringList;
  lAfter: TStringList;
  lDeniedReason: string;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then begin
    Result := xeAutomationErrorsBuildConsentRequired('files.sort_masters', 'files-mutation', lDeniedReason);
    Exit;
  end;

  lFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  // Reuse the same mutation guard as header flags because master ordering changes
  // the file header and must not bypass protected-target policy.
  xeAutomationRequireWritableTargetFile(lFile);

  lBefore := TStringList.Create;
  lAfter := TStringList.Create;
  try
    xeAutomationCaptureDirectMasters(lFile, lBefore);
    lFile.SortMasters;
    xeAutomationCaptureDirectMasters(lFile, lAfter);

    Result := TJsonObject.Create;
    try
      Result.S['fileName'] := lFile.FileName;
      xeAutomationWriteStringList(lBefore, Result.A['mastersBefore']);
      xeAutomationWriteStringList(lAfter, Result.A['mastersAfter']);
      Result.B['changed'] := not xeAutomationStringListsEqual(lBefore, lAfter);
      xeAutomationWriteDirtyFileNames(lFile, Result.A['dirtyFiles']);
      Result.B['requiresSave'] := lFile.Modified;
    except
      Result.Free;
      raise;
    end;
  finally
    lAfter.Free;
    lBefore.Free;
  end;
end;

function xeAutomationFileHygieneCleanMasters(const AArgs: TJsonObject): TJsonObject;
var
  lFile: IwbFile;
  lBefore: TStringList;
  lAfter: TStringList;
  lDeniedReason: string;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then begin
    Result := xeAutomationErrorsBuildConsentRequired('files.clean_masters', 'files-mutation', lDeniedReason);
    Exit;
  end;

  lFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  // CleanMasters can remove dependencies, so it is guarded identically to other
  // protected file mutations and still leaves saving to session.save.
  xeAutomationRequireWritableTargetFile(lFile);

  lBefore := TStringList.Create;
  lAfter := TStringList.Create;
  try
    xeAutomationCaptureDirectMasters(lFile, lBefore);
    lFile.CleanMasters;
    xeAutomationCaptureDirectMasters(lFile, lAfter);

    Result := TJsonObject.Create;
    try
      Result.S['fileName'] := lFile.FileName;
      xeAutomationWriteStringList(lBefore, Result.A['mastersBefore']);
      xeAutomationWriteStringList(lAfter, Result.A['mastersAfter']);
      xeAutomationWriteRemovedMasters(lBefore, lAfter, Result.A['removedMasters']);
      Result.B['changed'] := not xeAutomationStringListsEqual(lBefore, lAfter);
      xeAutomationWriteDirtyFileNames(lFile, Result.A['dirtyFiles']);
      Result.B['requiresSave'] := lFile.Modified;
    except
      Result.Free;
      raise;
    end;
  finally
    lAfter.Free;
    lBefore.Free;
  end;
end;

function xeAutomationReadBatchOperations(const AOptions: TJsonObject): TxeAutomationBatchOperations;
var
  lOperations: TJsonArray;
  lOperation: string;
  i: Integer;
begin
  if not Assigned(AOptions) then
    raise xeAutomationInvalidRequest('Automation files.hygiene.batch options are required');
  if not AOptions.Contains('operations') then
    raise xeAutomationInvalidRequest('Automation files.hygiene.batch options.operations is required');
  if AOptions.Types['operations'] <> jdtArray then
    raise xeAutomationInvalidRequest('Automation files.hygiene.batch options.operations must be an array');

  Result := [];
  lOperations := AOptions.A['operations'];
  if (lOperations.Count < 1) or (lOperations.Count > 32) then
    raise xeAutomationInvalidRequest('Automation files.hygiene.batch options.operations selects 1..32 entries');

  for i := 0 to Pred(lOperations.Count) do begin
    if lOperations.Types[i] <> jdtString then
      raise xeAutomationInvalidRequest('Automation files.hygiene.batch options.operations entries must be strings');
    lOperation := Trim(lOperations.S[i]);
    // The operation allow-list is enforced at jobs.start so active job conflicts
    // cannot mask a malformed batch request.
    if SameText(lOperation, 'sort_masters') then
      Include(Result, xaboSortMasters)
    else if SameText(lOperation, 'clean_masters') then
      Include(Result, xaboCleanMasters)
    else
      raise xeAutomationInvalidRequest(Format('Automation files.hygiene.batch operation "%s" is not supported', [lOperation]));
  end;
end;

procedure xeAutomationValidateFileHygieneBatchStart(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
var
  lFiles: TJsonArray;
  names: TStringList;
  fileRef: IwbFile;
  i: Integer;
begin
  if not Assigned(ATarget) or not ATarget.Contains('files') or
     (ATarget.Types['files'] <> jdtArray) then
    raise xeAutomationInvalidRequest('files.hygiene.batch target.files must be a plugin name array');
  if ATarget.Count <> 1 then
    raise xeAutomationInvalidRequest('files.hygiene.batch target accepts only files');
  xeAutomationReadBatchOperations(AOptions);
  if AOptions.Count <> 1 then
    raise xeAutomationInvalidRequest('files.hygiene.batch options accepts only operations');
  lFiles := ATarget.A['files'];
  if (lFiles.Count < 1) or (lFiles.Count > 256) then
    raise xeAutomationInvalidRequest('files.hygiene.batch selects 1..256 files');
  if not ADryRunSpecified then ADryRun := True;
  names := TStringList.Create;
  try
    names.CaseSensitive := False;
    for i := 0 to Pred(lFiles.Count) do begin
      if lFiles.Types[i] <> jdtString then
        raise xeAutomationInvalidRequest('files.hygiene.batch files entries must be strings');
      fileRef := xeAutomationRequirePluginFile(Trim(lFiles.S[i]));
      if names.IndexOf(fileRef.FileName) >= 0 then
        raise xeAutomationInvalidRequest('Duplicate files.hygiene.batch target');
      names.Add(fileRef.FileName);
      if not ADryRun then xeAutomationRequireWritableTargetFile(fileRef);
    end;
  finally names.Free; end;
end;

procedure xeAutomationAddBatchFinding(const AFindings: TJsonArray; const ASeverity, ACode, AMessage, AFileName,
  AActionKind, AReason, ARisk: string);
var
  lFinding: TJsonObject;
begin
  lFinding := TJsonObject.Create;
  try
    lFinding.S['severity'] := ASeverity;
    lFinding.S['code'] := ACode;
    lFinding.S['message'] := AMessage;
    lFinding.O['target'].S['file'] := AFileName;
    lFinding.S['source'] := 'files.hygiene.batch';
    lFinding.O['action'].S['kind'] := AActionKind;
    if AReason <> '' then
      lFinding.O['action'].S['reason'] := AReason;
    if ARisk <> '' then
      lFinding.O['action'].S['risk'] := ARisk;
    xeAutomationAppendJobFinding(AFindings, lFinding);
    lFinding := nil;
  finally
    lFinding.Free;
  end;
end;

function xeAutomationOperationName(const AOperation: TxeAutomationBatchOperation): string;
begin
  case AOperation of
    xaboSortMasters: Result := 'sort_masters';
    xaboCleanMasters: Result := 'clean_masters';
  else
    Result := 'unknown';
  end;
end;

function xeAutomationRunBatchOperation(const AFile: IwbFile; const AOperation: TxeAutomationBatchOperation): Boolean;
var
  lBefore: TStringList;
  lAfter: TStringList;
begin
  lBefore := TStringList.Create;
  lAfter := TStringList.Create;
  try
    xeAutomationCaptureDirectMasters(AFile, lBefore);
    case AOperation of
      xaboSortMasters: AFile.SortMasters;
      xaboCleanMasters: AFile.CleanMasters;
    end;
    xeAutomationCaptureDirectMasters(AFile, lAfter);
    Result := not xeAutomationStringListsEqual(lBefore, lAfter);
  finally
    lAfter.Free;
    lBefore.Free;
  end;
end;

procedure xeAutomationWriteBatchSummaryDefaults(const ASummary: TJsonObject);
begin
  ASummary.I['targets'] := 0;
  ASummary.I['findings'] := 0;
  ASummary.B['changed'] := False;
  ASummary.A['dirtyFiles'].Clear;
  ASummary.B['requiresSave'] := False;
  ASummary.I['planned'] := 0;
  ASummary.I['applied'] := 0;
  ASummary.I['skipped'] := 0;
  ASummary.B['partialChanges'] := False;
end;

procedure xeAutomationFileHygieneBatchJob(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
var
  lOperations: TxeAutomationBatchOperations;
  lFiles: TJsonArray;
  lFileName: string;
  lFile: IwbFile;
  lChanged: Boolean;
  i: Integer;

  procedure ProcessOperation(const AOperation: TxeAutomationBatchOperation);
  begin
    if ADryRun then begin
      ASummary.I['planned'] := ASummary.I['planned'] + 1;
      xeAutomationAddBatchFinding(AFindings, 'info', 'master_hygiene_planned',
        Format('Planned %s for %s', [xeAutomationOperationName(AOperation), lFile.FileName]),
        lFile.FileName, 'planned', 'dry_run', 'exact native result is available only in apply mode');
    end else begin
      lChanged := xeAutomationRunBatchOperation(lFile, AOperation);
      if lChanged then begin
        ASummary.B['changed'] := True;
        ASummary.B['requiresSave'] := True;
        xeAutomationAddUniqueString(ASummary.A['dirtyFiles'], lFile.FileName);
        ASummary.I['applied'] := ASummary.I['applied'] + 1;
        xeAutomationAddBatchFinding(AFindings, 'info', 'master_hygiene_applied',
          Format('Applied %s for %s', [xeAutomationOperationName(AOperation), lFile.FileName]),
          lFile.FileName, 'applied', '', '');
      end else begin
        ASummary.I['skipped'] := ASummary.I['skipped'] + 1;
        xeAutomationAddBatchFinding(AFindings, 'info', 'master_hygiene_skipped',
          Format('Skipped %s for %s because no master changes were needed', [xeAutomationOperationName(AOperation), lFile.FileName]),
          lFile.FileName, 'skipped', 'no_change', '');
      end;
    end;
  end;
begin
  lOperations := xeAutomationReadBatchOperations(AOptions);
  lFiles := ATarget.A['files'];
  xeAutomationWriteBatchSummaryDefaults(ASummary);
  ASummary.I['targets'] := lFiles.Count;

  for i := 0 to Pred(lFiles.Count) do begin
    lFileName := Trim(lFiles.S[i]);
    try
      lFile := xeAutomationRequirePluginFile(lFileName);
      if not ADryRun then
        // Apply mode must honor the exact protected-target policy used by the
        // single-file hygiene commands while still deferring persistence to save.
        xeAutomationRequireWritableTargetFile(lFile);

      if xaboSortMasters in lOperations then
        ProcessOperation(xaboSortMasters);
      if xaboCleanMasters in lOperations then
        ProcessOperation(xaboCleanMasters);
    except
      on E: ExeAutomationError do begin
        xeAutomationAddBatchFinding(AFindings, 'error', 'master_hygiene_failed', E.Message, lFileName, 'failed', E.Code, '');
        AFailure.S['code'] := E.Code;
        AFailure.S['message'] := E.Message;
        AFailure.S['phase'] := 'execution';
        AFailure.B['partial'] := ASummary.B['changed'];
        ASummary.B['partialChanges'] := ASummary.B['changed'];
        Break;
      end;
      on E: Exception do begin
        xeAutomationAddBatchFinding(AFindings, 'error', 'master_hygiene_failed', E.Message, lFileName, 'failed', xeAutomationErrorInternalError, '');
        AFailure.S['code'] := xeAutomationErrorInternalError;
        AFailure.S['message'] := E.Message;
        AFailure.S['phase'] := 'execution';
        AFailure.B['partial'] := ASummary.B['changed'];
        ASummary.B['partialChanges'] := ASummary.B['changed'];
        Break;
      end;
    end;
  end;

  ASummary.I['findings'] := AFindings.Count;
end;

type
  THygienePhase = (hpOperation, hpScan, hpClean, hpComplete);
  THygieneStepper = class(TxeAutomationJobStepper)
  private
    FFile: IwbFile;
    FFileName: string;
    FDryRun: Boolean;
    FOperations: TxeAutomationBatchOperations;
    FOperation: TxeAutomationBatchOperation;
    FPhase: THygienePhase;
    FScan: TwbAutomationMasterUseScan;
    FRow, FOperationRow: TJsonObject; // Durable result owns these rows.
    FBefore: TStringList;
    FSnapshot: TxeAutomationMutationSnapshot;
    FLastWork, FLastMutations, FSteps, FScanWork, FNativeUnits, FDepth: Integer;
    procedure Initialize(const summary, resultData: TJsonObject);
    procedure CompleteOperation(const findings: TJsonArray; const summary: TJsonObject);
    procedure UpdateAudit(const summary: TJsonObject);
  public
    constructor Create(const fileName: string; const dry: Boolean;
      const operations: TxeAutomationBatchOperations);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray;
      const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor THygieneStepper.Create(const fileName: string; const dry: Boolean;
  const operations: TxeAutomationBatchOperations);
begin
  inherited Create;
  FFileName := fileName;
  FDryRun := dry;
  FOperations := operations;
  FBefore := TStringList.Create;
end;

destructor THygieneStepper.Destroy;
begin
  FScan.Free;
  FBefore.Free;
  FSnapshot.Files := nil;
  FFile := nil;
  inherited;
end;

procedure THygieneStepper.Initialize(const summary, resultData: TJsonObject);
begin
  FFile := xeAutomationRequirePluginFile(FFileName);
  if not FDryRun then xeAutomationRequireWritableTargetFile(FFile);
  FSnapshot := xeAutomationCaptureMutationSnapshot;
  summary.I['targets'] := summary.I['targets'] + 1;
  summary.B['dryRun'] := FDryRun;
  summary.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush';
  summary.S['cancellation'] := 'between structural scan steps and native sort/remap calls';
  FRow := resultData.A['files'].AddObject;
  FRow.S['fileName'] := FFile.FileName;
  FRow.B['dirtyBefore'] := FFile.Modified;
  FRow.B['complete'] := False;
  FRow.A['operations'].Clear;
  if xaboSortMasters in FOperations then FOperation := xaboSortMasters
  else FOperation := xaboCleanMasters;
  UpdateAudit(summary);
end;

procedure THygieneStepper.UpdateAudit(const summary: TJsonObject);
begin
  xeAutomationWriteMutationAudit(FRow.O['mutationState'], FSnapshot);
  FRow.B['requiresSave'] := FFile.Modified;
  if FRow.O['mutationState'].B['mutationsObserved'] then summary.B['changed'] := True;
  summary.B['requiresSave'] := summary.B['requiresSave'] or FFile.Modified;
  if FFile.Modified then xeAutomationAddUniqueString(summary.A['dirtyFiles'], FFile.FileName);
end;

procedure THygieneStepper.CompleteOperation(const findings: TJsonArray; const summary: TJsonObject);
var afterMasters: TStringList; changed: Boolean; outcome, reason: string;
begin
  afterMasters := TStringList.Create;
  try
    xeAutomationCaptureDirectMasters(FFile, afterMasters);
    xeAutomationWriteStringList(afterMasters, FOperationRow.A['mastersAfter']);
    xeAutomationWriteRemovedMasters(FBefore, afterMasters, FOperationRow.A['removedMasters']);
    changed := not xeAutomationStringListsEqual(FBefore, afterMasters);
    FOperationRow.B['changed'] := changed;
    FOperationRow.B['complete'] := True;
    reason := '';
    if FDryRun then begin
      outcome := 'planned'; reason := 'dry_run';
    end else if changed then outcome := 'applied'
    else begin outcome := 'skipped'; reason := 'no_change'; end;
    FOperationRow.S['outcome'] := outcome;
    summary.I[outcome] := summary.I[outcome] + 1;
    FRow.I[outcome] := FRow.I[outcome] + 1;
    // Copy immutable events only after the durable operation row is finalized.
    xeAutomationAddBatchFinding(findings, 'info', 'master_hygiene_' + outcome,
      Format('%s %s for %s', [outcome, xeAutomationOperationName(FOperation), FFile.FileName]),
      FFile.FileName, outcome, reason, 'native calls indivisible; dry run does not predict unused masters');
    summary.I['findings'] := findings.Count;
    FOperationRow := nil;
    if (FOperation = xaboSortMasters) and (xaboCleanMasters in FOperations) then begin
      FOperation := xaboCleanMasters;
      FPhase := hpOperation;
    end else begin
      FPhase := hpComplete;
      FRow.B['complete'] := True;
    end;
  finally afterMasters.Free; end;
end;

function THygieneStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var timer: TStopwatch; scanDone: Boolean; code: string;
begin
  Inc(FSteps); FLastWork := 0; FLastMutations := 0;
  try
    if not Assigned(FRow) then Initialize(summary, resultData);
    case FPhase of
      hpOperation: begin
        FOperationRow := FRow.A['operations'].AddObject;
        FOperationRow.S['operation'] := xeAutomationOperationName(FOperation);
        FOperationRow.S['outcome'] := 'pending';
        FOperationRow.B['complete'] := False;
        xeAutomationCaptureDirectMasters(FFile, FBefore);
        xeAutomationWriteStringList(FBefore, FOperationRow.A['mastersBefore']);
        FLastWork := 1;
        if FDryRun then CompleteOperation(findings, summary)
        else if FOperation = xaboSortMasters then begin
          xeAutomationRequireWritableTargetFile(FFile);
          FLastMutations := 1;
          FFile.SortMasters;
          UpdateAudit(summary);
          CompleteOperation(findings, summary);
        end else begin
          FScan := wbAutomationMasterUseScan(FFile);
          FPhase := hpScan;
        end;
      end;
      hpScan: begin
        timer := TStopwatch.StartNew;
        repeat
          Inc(FLastWork);
          try
            scanDone := FScan.Advance;
          finally
            FScanWork := FScan.WorkUnits;
            FNativeUnits := FScan.NativeUnits;
            FDepth := FScan.RetainedDepth;
          end;
          if scanDone then begin
            FOperationRow.B['scanComplete'] := True;
            FPhase := hpClean;
            Break; // Leave a cancelable boundary BEFORE the native remap.
          end;
        until (FLastWork >= xeAutomationJobStepWorkLimit) or
              (timer.ElapsedMilliseconds >= xeAutomationJobStepBudgetMs);
      end;
      hpClean: begin
        xeAutomationRequireWritableTargetFile(FFile);
        FLastWork := 1; FLastMutations := 1;
        FScan.Apply;
        FreeAndNil(FScan);
        FDepth := 0;
        UpdateAudit(summary);
        CompleteOperation(findings, summary);
      end;
    end;
  except
    on E: Exception do begin
      code := xeAutomationErrorInternalError;
      if E is ExeAutomationError then code := ExeAutomationError(E).Code
      else if E is EwbAutomationMasterScanInvalidated then code := 'job_invalidated'
      else if E is EwbAutomationMasterScanCapacity then code := 'job_capacity';
      failure.S['code'] := code;
      failure.S['message'] := Copy(E.Message, 1, 4096);
      failure.S['phase'] := 'master-hygiene';
      failure.S['operation'] := xeAutomationOperationName(FOperation);
      if Assigned(FRow) then begin
        UpdateAudit(summary);
        failure.B['partial'] := summary.B['changed'];
        failure.B['partialKnown'] := True;
        summary.B['partialChanges'] := summary.B['changed'];
        if Assigned(FOperationRow) then begin
          if not FOperationRow.B['complete'] then begin
            FOperationRow.S['outcome'] := 'failed';
            FOperationRow.S['errorCode'] := code;
          end else FOperationRow.S['findingErrorCode'] := code;
        end;
      end;
    end;
  end;
  Result := (FPhase = hpComplete) and (failure.Count = 0);
end;

procedure THygieneStepper.WriteProgress(const progress: TJsonObject);
const phases: array[THygienePhase] of string = ('operation', 'scan-masters', 'apply-clean-masters', 'complete');
begin
  progress.S['fileName'] := FFileName;
  progress.S['phase'] := phases[FPhase];
  progress.S['operation'] := xeAutomationOperationName(FOperation);
  progress.I['steps'] := FSteps;
  progress.I['lastWorkUnits'] := FLastWork;
  progress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.I['lastMutations'] := FLastMutations;
  progress.I['mutationLimit'] := 1;
  progress.I['scanWorkUnits'] := FScanWork;
  progress.I['scanWorkLimit'] := wbAutomationMasterScanWorkLimit;
  progress.I['nativeUsageCalls'] := FNativeUnits;
  progress.I['retainedDepth'] := FDepth;
  progress.I['depthLimit'] := wbAutomationMasterScanDepthLimit;
  progress.B['nativeCallsPreemptible'] := False;
  progress.S['nativeAtoms'] := 'container initialization; one record usage lookup; final master remapping; sorting';
end;

function NewHygieneStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin
  Result := THygieneStepper.Create(target.A['files'].S[0], dry, xeAutomationReadBatchOperations(options));
end;

procedure xeAutomationRegisterFileHygieneCommands;
begin
  xeAutomationRegisterCommand('files.get_header', xeAutomationFileHygieneGetHeader);
  xeAutomationRegisterCommand('files.get_masters', xeAutomationFileHygieneGetMasters);
  xeAutomationRegisterCommand('files.set_header_flags', xeAutomationFileHygieneSetHeaderFlags);
  xeAutomationRegisterCommand('files.sort_masters', xeAutomationFileHygieneSortMasters);
  xeAutomationRegisterCommand('files.clean_masters', xeAutomationFileHygieneCleanMasters);
  // Register the first concrete job kind from the command unit that owns the
  // native helpers so batch execution can reuse them without registry roundtrips.
  xeAutomationRegisterJobKindWithValidator('files.hygiene.batch', xeAutomationFileHygieneBatchJob,
    xeAutomationValidateFileHygieneBatchStart);
  xeAutomationRegisterJobStepper('files.hygiene.batch', NewHygieneStepper);
end;

end.
