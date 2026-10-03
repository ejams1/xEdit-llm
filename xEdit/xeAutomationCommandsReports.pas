{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsReports;
interface
procedure xeAutomationRegisterReportCommands;
implementation
uses Classes, SysUtils, System.Generics.Collections, JsonDataObjects,
  wbInterface, wbHelpers, xeMainForm, xeAutomationRecordComparison,
  xeAutomationDataLookup, xeAutomationObjectModel, xeAutomationErrors,
  xeAutomationRegistry, xeAutomationExternalIO, xeAutomationMutationPolicy,
  xeAutomationMutationAudit;

procedure RequireSaved(const fileRef: IwbFile);
begin
  if fileRef.Modified or xeSavePluginFilePendingShutdown(fileRef) or
     not FileExists(wbExpandFileName(fileRef.FileNameOnDisk)) then
    raise xeAutomationStateConflict('Report sources and masters must be saved and flushed; restart after saving: ' + fileRef.FileName);
end;

function DiskCRC(const stream: TFileStream): Cardinal;
var data: TBytes;
begin
  // wbCRC32File allocates the entire input without a bound. Report sources are
  // intentionally small; enforce the budget before using the same native CRC.
  if (stream.Size < 1) or (stream.Size > 67108864) then
    raise xeAutomationNewError('report_capacity', 'Each report source must be 1 byte..64 MiB');
  SetLength(data, stream.Size);
  stream.Position := 0; stream.ReadBuffer(data[0], Length(data));
  Result := Cardinal(wbCRC32Data(data));
end;

procedure AddIdentity(const list: TJsonArray; const recordRef: IwbMainRecord; const reason: string = '');
var row: TJsonObject;
begin
  row := list.AddObject;
  row.S['file'] := recordRef._File.FileName;
  row.S['formId'] := recordRef.LoadOrderFormID.ToString(False);
  row.S['signature'] := recordRef.Signature; row.S['path'] := '';
  // Root identity is sufficient for readback; avoid unbounded EditorID previews.
  if reason <> '' then row.S['reason'] := reason;
end;

function CleaningReport(const args: TJsonObject): TJsonObject;
var
  files: TJsonArray; sources: TList<IwbFile>; streams: TObjectList<TFileStream>;
  names: TStringList; fileRef, master: IwbFile; recordRef: IwbMainRecord;
  row: TJsonObject; info: TLOOTPluginInfo; snapshot: TxeAutomationMutationSnapshot;
  formatName, outputRoot, outputPath, textValue, denied, removalReason: string;
  dry, overwrite, specified, navmesh: Boolean; i, j, scanned: Integer;
  stream: TFileStream; output: TMemoryStream; encoded: TBytes;
begin
  if wbGameMode = gmTES3 then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Cleaning reports require plugin records');
  if wbTranslationMode then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Cleaning reports are unavailable in translation mode');
  if not Assigned(MainForm) then raise xeAutomationStateConflict('Native report formatter is unavailable');
  formatName := LowerCase(xeAutomationRequireStringArg(args, 'format'));
  if (formatName <> 'loot') and (formatName <> 'boss') then raise xeAutomationInvalidRequest('format must be loot or boss');
  if (formatName = 'boss') and (wbGameMode <> gmTES4) then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Native BOSS report output requires classic Oblivion');
  if not args.Contains('files') or (args.Types['files'] <> jdtArray) then raise xeAutomationInvalidRequest('files must be a plugin array');
  files := args.A['files'];
  if (files.Count < 1) or (files.Count > 8) then raise xeAutomationInvalidRequest('Select 1..8 report source files');
  dry := xeAutomationReadBooleanArg(args, 'dryRun', specified); if not specified then dry := True;
  overwrite := xeAutomationReadBooleanArg(args, 'overwrite', specified);
  outputPath := '';
  if args.Contains('outputDirectory') then begin
    outputRoot := xeAutomationExternalRoot(xeAutomationRequireStringArg(args, 'outputDirectory'));
    if formatName = 'loot' then outputPath := outputRoot + 'xedit-cleaning-loot.yaml'
    else outputPath := outputRoot + 'xedit-cleaning-boss.txt';
    if FileExists(outputPath) and not overwrite then raise xeAutomationStateConflict('Report output exists; set overwrite:true to replace it');
    if not dry and not xeAutomationMutationPolicyConsentSatisfied(denied) then
      Exit(xeAutomationErrorsBuildConsentRequired('reports.cleaning', 'external-file-write', denied));
  end;
  sources := TList<IwbFile>.Create; streams := TObjectList<TFileStream>.Create(True);
  names := TStringList.Create; names.CaseSensitive := False;
  Result := TJsonObject.Create;
  try
    try
      scanned := 0;
      // Retain deny-write handles through classification and optional export.
      // Source CRC must match xEdit's loaded snapshot, not a later external edit.
      for i := 0 to files.Count - 1 do begin
        if files.Types[i] <> jdtString then raise xeAutomationInvalidRequest('files entries must be plugin names');
        fileRef := xeAutomationRequirePluginFile(Trim(files.S[i]));
        if names.IndexOf(fileRef.FileName) >= 0 then raise xeAutomationInvalidRequest('Duplicate report source');
        names.Add(fileRef.FileName); RequireSaved(fileRef);
        for master in fileRef.AllMasters do RequireSaved(master);
        Inc(scanned, fileRef.RecordCount);
        if scanned > 1000 then raise xeAutomationNewError('report_capacity', 'Report scans at most 1000 source records');
        stream := TFileStream.Create(wbExpandFileName(fileRef.FileNameOnDisk), fmOpenRead or fmShareDenyWrite);
        streams.Add(stream);
        if DiskCRC(stream) <> Cardinal(fileRef.CRC32) then
          raise xeAutomationStateConflict('Loaded source CRC differs from disk; restart before reporting: ' + fileRef.FileName);
        sources.Add(fileRef);
      end;
      snapshot := xeAutomationCaptureMutationSnapshot;
      Result.S['format'] := formatName; Result.B['dryRun'] := dry;
      Result.B['written'] := False; Result.B['complete'] := False;
      Result.I['scannedRecords'] := scanned;
      Result.S['classification'] := 'native removable ITM, editable cleanable deleted refs, and manual deleted NAVM; skipped identities are separate';
      Result.S['dependencyState'] := 'clean saved loaded masters; classification uses their loaded snapshot, without rehashing master disk files';
      Result.S['sourceState'] := 'current clean loaded snapshot; source CRC checked against disk; no GUI historical entries';
      Result.S['persistence'] := 'read-only plugin scan; optional immediate UTF-8 external output';
      Result.S['encoding'] := 'utf-8-no-bom'; Result.A['files'].Clear;
      textValue := '';
      for i := 0 to sources.Count - 1 do begin
        fileRef := sources[i]; info := Default(TLOOTPluginInfo);
        info.Plugin := fileRef.FileName; info.CRC32 := Cardinal(fileRef.CRC32);
        row := Result.A['files'].AddObject;
        row.S['file'] := info.Plugin; row.S['crc32'] := IntToHex(info.CRC32, 8);
        row.A['itm'].Clear; row.A['udr'].Clear; row.A['nav'].Clear; row.A['skipped'].Clear;
        for j := 0 to fileRef.RecordCount - 1 do
          if Supports(fileRef.Records[j], IwbMainRecord, recordRef) then begin
            if xeAutomationRecordIsIdenticalToMaster(recordRef) then begin
              removalReason := xeAutomationIdenticalRecordRemovalReason(recordRef);
              if removalReason = '' then AddIdentity(row.A['itm'], recordRef)
              else AddIdentity(row.A['skipped'], recordRef, removalReason);
            end;
            if xeAutomationRecordIsDeletedRefCandidate(recordRef) then
              if xeAutomationDeletedRefCanBeCleaned(recordRef, navmesh) then
                if recordRef.IsEditable then AddIdentity(row.A['udr'], recordRef)
                else AddIdentity(row.A['skipped'], recordRef, 'udr-not-editable')
              else if navmesh then AddIdentity(row.A['nav'], recordRef)
              else AddIdentity(row.A['skipped'], recordRef, 'udr-native-ineligible');
          end;
        info.ITM := row.A['itm'].Count; info.UDR := row.A['udr'].Count; info.NAV := row.A['nav'].Count;
        row.O['counts'].I['itm'] := info.ITM; row.O['counts'].I['udr'] := info.UDR; row.O['counts'].I['nav'] := info.NAV;
        row.B['clean'] := (info.ITM = 0) and (info.UDR = 0) and (info.NAV = 0);
        row.S['text'] := MainForm.AutomationCleaningReport(info, formatName = 'boss');
        textValue := textValue + row.S['text'];
        if DiskCRC(streams[i]) <> info.CRC32 then raise xeAutomationStateConflict('Report source changed during scan');
      end;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], snapshot);
      if Result.O['mutationState'].B['mutationsObserved'] then raise xeAutomationStateConflict('Report scan changed plugin state');
      Result.S['text'] := textValue;
      if outputPath <> '' then begin
        Result.S['outputPath'] := outputPath;
        if not dry then begin
          encoded := TEncoding.UTF8.GetBytes(textValue);
          output := TMemoryStream.Create;
          try
            if Length(encoded) > 0 then output.WriteBuffer(encoded[0], Length(encoded));
            xeAutomationAtomicWrite(outputPath, output, overwrite);
          finally output.Free; end;
          Result.B['written'] := True;
        end;
      end;
      Result.B['complete'] := True;
    except Result.Free; raise; end;
  finally names.Free; streams.Free; sources.Free; end;
end;

procedure xeAutomationRegisterReportCommands;
begin xeAutomationRegisterCommand('reports.cleaning', CleaningReport); end;
end.
