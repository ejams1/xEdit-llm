{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationExternalIO;
interface
uses Classes;
function xeAutomationExternalRoot(const APath: string): string;
procedure xeAutomationAtomicWrite(const APath: string; const AData: TStream; AOverwrite: Boolean);
implementation
uses Windows, SysUtils, JsonDataObjects, xeAutomationErrors;

function xeAutomationExternalRoot(const APath: string): string;
var lDrive: string;
begin
  lDrive := ExtractFileDrive(APath);
  if (lDrive = '') or (Length(APath) > 180) or (Length(APath) <= Length(lDrive)) or
     (APath[Length(lDrive) + 1] <> '\') then
    raise xeAutomationInvalidRequest('Output directory must be an absolute existing path <=180 characters');
  Result := IncludeTrailingPathDelimiter(ExpandFileName(APath));
  if not DirectoryExists(Result) then raise xeAutomationInvalidTarget('Output directory does not exist');
end;

procedure xeAutomationAtomicWrite(const APath: string; const AData: TStream; AOverwrite: Boolean);
var
  lTemp: string;
  lGuid: TGUID;
  lHandle: THandle;
  lStream: THandleStream;
  lFlags: Cardinal;
  lCreated: Boolean;
  lDetails: TJsonObject;
begin
  if (AData.Size > 67108864) or (Length(APath) > 240) then
    raise xeAutomationNewError('export_capacity', 'External output exceeds its size/path budget');
  if not AOverwrite and FileExists(APath) then raise xeAutomationStateConflict('External output already exists');
  CreateGUID(lGuid);
  lTemp := ExtractFilePath(APath) + Copy(GUIDToString(lGuid), 2, 16) + '.tmp';
  lCreated := False;
  try
    // CREATE_NEW establishes ownership. Never delete a collided pre-existing temp.
    lHandle := CreateFile(PChar(lTemp), GENERIC_WRITE, 0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if lHandle = INVALID_HANDLE_VALUE then RaiseLastOSError;
    lCreated := True;
    try
      lStream := THandleStream.Create(lHandle);
      try
        AData.Position := 0;
        lStream.CopyFrom(AData, AData.Size);
        if not FlushFileBuffers(lHandle) then RaiseLastOSError;
      finally lStream.Free; end;
    finally CloseHandle(lHandle); end;
    lFlags := MOVEFILE_WRITE_THROUGH;
    if AOverwrite then lFlags := lFlags or MOVEFILE_REPLACE_EXISTING;
    if not MoveFileEx(PChar(lTemp), PChar(APath), lFlags) then RaiseLastOSError;
    lCreated := False;
  except
    on E: Exception do begin
      lDetails := TJsonObject.Create;
      try
        lDetails.S['temporaryPath'] := lTemp;
        lDetails.B['temporaryCreated'] := lCreated;
        lDetails.B['temporaryRemoved'] := not lCreated or not FileExists(lTemp) or SysUtils.DeleteFile(lTemp);
        lDetails.B['partial'] := not lDetails.B['temporaryRemoved'];
        lDetails.B['partialKnown'] := True;
        raise xeAutomationNewError('external_output_failed', E.Message, lDetails);
      finally lDetails.Free; end;
    end;
  end;
end;
end.
