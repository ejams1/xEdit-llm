{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationCommandsExports;

interface

procedure xeAutomationRegisterExportCommands;

implementation

uses
  Windows, Classes, SysUtils, JsonDataObjects, wbInterface,
  xeAutomationDataLookup, xeAutomationErrors, xeAutomationMutationPolicy,
  xeAutomationRegistry;

function xeAutomationExportSeq(const AArgs: TJsonObject): TJsonObject;
var
  lFile: IwbFile;
  lGroup: IwbGroupRecord;
  lRecord: IwbMainRecord;
  lFlags: IwbElement;
  lIds: TwbFormIDs;
  lPath, lDirectory, lTemp, lDenied, lDrive: string;
  lDryRun, lOverwrite, lSpecified, lTempCreated: Boolean;
  lRow: TJsonObject;
  lGuid: TGUID;
  lHandle: THandle;
  lStream: THandleStream;
  lMoveFlags: Cardinal;
  i: Integer;
begin
  // Preserve the actual Skyrim family menu predicate and exact native SGE
  // eligibility. This command exports loaded data; it never saves a plugin.
  if not wbIsSkyrim then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'SEQ export requires a Skyrim-family game');
  lDryRun := xeAutomationReadBooleanArg(AArgs, 'dryRun', lSpecified);
  if not lSpecified then lDryRun := True;
  lOverwrite := xeAutomationReadBooleanArg(AArgs, 'overwrite', lSpecified);
  if not lSpecified then lOverwrite := False;
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDenied) then
    Exit(xeAutomationErrorsBuildConsentRequired('exports.seq', 'external-file-write', lDenied));
  lFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'file'));
  lPath := xeAutomationRequireStringArg(AArgs, 'outputPath');
  lDrive := ExtractFileDrive(lPath);
  if (Length(lPath) > 240) or (lDrive = '') or
     (Length(lPath) <= Length(lDrive)) or (lPath[Length(lDrive) + 1] <> '\') then
    raise xeAutomationInvalidRequest('outputPath must be an absolute path of at most 240 characters');
  lPath := ExpandFileName(lPath);
  if not SameText(ExtractFileName(lPath), ChangeFileExt(lFile.FileName, '.seq')) then
    raise xeAutomationInvalidRequest('SEQ output filename must match the selected plugin basename');
  lDirectory := ExtractFilePath(lPath);
  if not DirectoryExists(lDirectory) then
    raise xeAutomationInvalidTarget('SEQ output directory must already exist');
  lGroup := lFile.GroupBySignature['QUST'];
  if (lFile.LoadOrder <> 0) and Assigned(lGroup) and (lGroup.ElementCount > 10000) then
    raise xeAutomationNewError('export_capacity', 'SEQ export scans at most 10000 quests');
  Result := TJsonObject.Create;
  try
    Result.B['dryRun'] := lDryRun;
    Result.B['overwrite'] := lOverwrite;
    Result.B['complete'] := False;
    Result.B['changed'] := False;
    Result.B['written'] := False;
    Result.S['file'] := lFile.FileName;
    Result.S['outputPath'] := lPath;
    Result.S['persistence'] := 'immediate-external-binary-output; no-plugin-save-or-session-flush-required-for-export';
    Result.B['sourceModified'] := lFile.Modified;
    Result.S['sourceState'] := 'loaded-memory; save the source separately if it has pending plugin changes';
    Result.S['encoding'] := 'headerless-little-endian-file-local-fixed-formids-u32';
    Result.A['eligible'].Clear;
    Result.I['skippedNotStartGameEnabled'] := 0;
    Result.I['skippedAlreadyEnabledInMaster'] := 0;
    if lFile.LoadOrder = 0 then Result.S['skipReason'] := 'load-order-zero'
    else if Assigned(lGroup) then
      for i := 0 to lGroup.ElementCount - 1 do
        if Supports(lGroup.Elements[i], IwbMainRecord, lRecord) then begin
          lFlags := lRecord.ElementByPath['DNAM - General\Flags'];
          if not Assigned(lFlags) or ((lFlags.NativeValue and 1) = 0) then begin
            Result.I['skippedNotStartGameEnabled'] := Result.I['skippedNotStartGameEnabled'] + 1;
            Continue;
          end;
          if Assigned(lRecord.Master) and ((lRecord.Master.ElementNativeValues['DNAM\Flags'] and 1) <> 0) then begin
            Result.I['skippedAlreadyEnabledInMaster'] := Result.I['skippedAlreadyEnabledInMaster'] + 1;
            Continue;
          end;
          if Length(lIds) >= 1000 then raise xeAutomationNewError('export_capacity', 'SEQ output allows at most 1000 eligible quests');
          SetLength(lIds, Length(lIds) + 1);
          lIds[High(lIds)] := lRecord.FixedFormID;
          lRow := Result.A['eligible'].AddObject;
          lRow.S['file'] := lFile.FileName;
          lRow.S['formId'] := lRecord.LoadOrderFormID.ToString(False);
          lRow.S['fixedFormId'] := lRecord.FixedFormID.ToString(False);
          lRow.S['editorId'] := Copy(lRecord.EditorID, 1, 255);
        end;
    Result.I['questCount'] := Length(lIds);
    Result.I['bytes'] := Length(lIds) * SizeOf(Cardinal);
    if Length(lIds) = 0 then begin
      if not Result.Contains('skipReason') then Result.S['skipReason'] := 'no-eligible-quests';
      Result.B['existingOutputRetained'] := FileExists(lPath);
      Result.B['complete'] := True;
      Exit;
    end;
    if FileExists(lPath) and not lOverwrite then
      raise xeAutomationStateConflict('SEQ output exists; set overwrite:true to replace it');
    if lDryRun then begin Result.B['complete'] := True; Exit; end;
    // Stage and flush a new file in the destination directory, then rename with
    // an atomic overwrite policy. A racing creator must not be truncated when
    // overwrite:false; no partial SEQ bytes are ever exposed at outputPath.
    CreateGUID(lGuid);
    lTemp := lDirectory + Copy(GUIDToString(lGuid), 2, 16) + '.tmp';
    lTempCreated := False;
    lHandle := INVALID_HANDLE_VALUE;
    try
      lHandle := CreateFile(PChar(lTemp), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
      if lHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
      lTempCreated := True;
      lStream := THandleStream.Create(lHandle);
      try lStream.WriteBuffer(lIds[0], Length(lIds) * SizeOf(Cardinal));
      finally lStream.Free; end;
      if not FlushFileBuffers(lHandle) then RaiseLastOSError;
      CloseHandle(lHandle);
      lHandle := INVALID_HANDLE_VALUE;
      lMoveFlags := MOVEFILE_WRITE_THROUGH;
      if lOverwrite then lMoveFlags := lMoveFlags or MOVEFILE_REPLACE_EXISTING;
      if not MoveFileEx(PChar(lTemp), PChar(lPath), lMoveFlags) then RaiseLastOSError;
      Result.B['changed'] := True;
      Result.B['written'] := True;
      Result.B['complete'] := True;
    except
      on E: Exception do begin
        if lHandle <> INVALID_HANDLE_VALUE then begin CloseHandle(lHandle); lHandle := INVALID_HANDLE_VALUE; end;
        Result.O['failure'].S['code'] := 'external_output_failed';
        Result.O['failure'].S['message'] := E.Message;
        Result.O['failure'].S['temporaryPath'] := lTemp;
        Result.O['failure'].B['temporaryCreated'] := lTempCreated;
        Result.O['failure'].B['temporaryRemoved'] := not lTempCreated or not FileExists(lTemp) or DeleteFile(PChar(lTemp));
        Result.O['failure'].B['partial'] := not Result.O['failure'].B['temporaryRemoved'];
        Result.O['failure'].B['partialKnown'] := True;
      end;
    end;
  except Result.Free; raise; end;
end;

procedure xeAutomationRegisterExportCommands;
begin
  xeAutomationRegisterCommand('exports.seq', xeAutomationExportSeq);
end;

end.
