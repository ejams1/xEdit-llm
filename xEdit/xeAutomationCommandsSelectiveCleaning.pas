{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsSelectiveCleaning;
interface
procedure xeAutomationRegisterSelectiveCleaningJobs;
implementation
uses Classes, SysUtils, System.Generics.Collections, JsonDataObjects,
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

procedure Run(const kind: string; dry: Boolean; const target: TJsonObject;
  const findings: TJsonArray; const summary, resultData, failure: TJsonObject);
var
  fileRef: IwbFile; recordRef: IwbMainRecord; plan: TList<IwbMainRecord>;
  row, fileRow, finding: TJsonObject; snapshot: TxeAutomationMutationSnapshot;
  reason: string; navmesh: Boolean; i, planned, applied, skipped: Integer;
begin
  fileRef := xeAutomationRequirePluginFile(Trim(target.A['files'].S[0]));
  if not dry then xeAutomationRequireWritableCleaningTarget(fileRef);
  snapshot := xeAutomationCaptureMutationSnapshot;
  planned := 0; applied := 0; skipped := 0;
  plan := TList<IwbMainRecord>.Create;
  try
    summary.S['kind'] := kind; summary.B['dryRun'] := dry;
    summary.I['targets'] := 1;
    summary.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush';
    summary.S['cancellation'] := 'between-files';
    summary.A['dirtyFiles'].Clear;
    fileRow := resultData.A['files'].AddObject;
    fileRow.S['fileName'] := fileRef.FileName; fileRow.S['operation'] := kind;
    fileRow.B['dirtyBefore'] := fileRef.Modified;
    fileRow.A['records'].Clear; fileRow.A['masters'].Clear;
    for i := 0 to fileRef.MasterCount[True] - 1 do
      fileRow.A['masters'].Add(fileRef.Masters[i, True].FileName);
    if kind = UdrKind then begin
      fileRow.O['nativeSettings'].B['setZ'] := wbUDRSetZ;
      fileRow.O['nativeSettings'].F['z'] := wbUDRSetZValue;
      fileRow.O['nativeSettings'].B['setXESP'] := wbUDRSetXESP;
      fileRow.O['nativeSettings'].B['setScale'] := wbUDRSetScale;
      fileRow.O['nativeSettings'].F['scale'] := wbUDRSetScaleValue;
      fileRow.O['nativeSettings'].B['setMSTT'] := wbUDRSetMSTT;
      fileRow.O['nativeSettings'].S['msttFormId'] := IntToHex(wbUDRSetMSTTValue, 8);
    end;
    // Classification finishes before the first write. Pin only eligible roots,
    // retain identical parents, and keep NAVM/manual repair outside UDR apply.
    for i := 0 to fileRef.RecordCount - 1 do
      if Supports(fileRef.Records[i], IwbMainRecord, recordRef) then begin
        reason := '';
        if kind = ItmKind then begin
          if not xeAutomationRecordIsIdenticalToMaster(recordRef) then Continue;
          reason := xeAutomationIdenticalRecordRemovalReason(recordRef);
        end else begin
          if not xeAutomationRecordIsDeletedRefCandidate(recordRef) then Continue;
          if not xeAutomationDeletedRefCanBeCleaned(recordRef, navmesh) then begin
            if navmesh then reason := 'unsafe-navmesh' else reason := 'native-ineligible';
          end else if not recordRef.IsEditable then reason := 'not-editable';
        end;
        row := fileRow.A['records'].AddObject;
        row.O['locator'].S['file'] := fileRef.FileName;
        row.O['locator'].S['formId'] := recordRef.LoadOrderFormID.ToString(False);
        row.O['locator'].S['path'] := ''; row.S['signature'] := recordRef.Signature;
        if reason <> '' then begin
          row.S['outcome'] := 'skipped'; row.S['reason'] := reason; Inc(skipped);
        end else begin
          row.S['outcome'] := 'planned'; row.I['planIndex'] := plan.Count;
          plan.Add(recordRef); Inc(planned);
        end;
      end;
    if not dry then
      for i := 0 to fileRow.A['records'].Count - 1 do begin
        row := fileRow.A['records'].O[i];
        if row.S['outcome'] <> 'planned' then Continue;
        recordRef := plan[row.I['planIndex']];
        row.S['outcome'] := 'attempted';
        try
          if kind = ItmKind then begin
            if not xeAutomationRecordIsIdenticalToMaster(recordRef) or
               (xeAutomationIdenticalRecordRemovalReason(recordRef) <> '') then
              raise xeAutomationStateConflict('ITM no longer removable');
            recordRef.Remove;
          end else begin
            xeAutomationUndeleteAndDisableRefInMemory(recordRef);
            row.B['deletedAfter'] := recordRef.IsDeleted;
            row.B['initiallyDisabledAfter'] := recordRef.IsInitiallyDisabled;
            if row.B['deletedAfter'] or not row.B['initiallyDisabledAfter'] then
              raise xeAutomationStateConflict('UDR flags did not match native readback');
          end;
          row.S['outcome'] := 'applied'; Inc(applied);
        except
          on E: Exception do begin
            // Keep successful earlier roots and the failing locator in durable
            // job state. The job manager attaches a full mutation audit.
            row.S['outcome'] := 'failed'; row.S['message'] := E.Message;
            if E is ExeAutomationError then failure.S['code'] := ExeAutomationError(E).Code
            else failure.S['code'] := xeAutomationErrorInternalError;
            failure.S['message'] := E.Message; failure.S['phase'] := kind;
            failure.I['completedRecords'] := applied;
            failure.O['locator'].Assign(row.O['locator']);
            Break;
          end;
        end;
      end;
    summary.I['planned'] := planned; summary.I['applied'] := applied; summary.I['skipped'] := skipped;
    xeAutomationWriteMutationAudit(fileRow.O['mutationState'], snapshot);
    fileRow.B['dirtyAfter'] := fileRef.Modified;
    summary.B['changed'] := fileRow.O['mutationState'].B['mutationsObserved'];
    summary.B['requiresSave'] := summary.B['changed'] and fileRef.Modified;
    if summary.B['requiresSave'] then summary.A['dirtyFiles'].Add(fileRef.FileName);
    finding := findings.AddObject;
    finding.S['source'] := kind; finding.S['severity'] := 'info';
    finding.S['code'] := 'selective_cleaning_counts'; finding.O['target'].S['file'] := fileRef.FileName;
    finding.O['counts'].I['planned'] := planned; finding.O['counts'].I['applied'] := applied;
    finding.O['counts'].I['skipped'] := skipped;
    summary.I['findings'] := findings.Count;
  finally plan.Free; end;
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
end;
end.
