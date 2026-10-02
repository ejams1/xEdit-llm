{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationTransportPipe;

interface

uses
  Windows,
  SysUtils;

function xeAutomationPipeNameForPid(const aPid: Cardinal): string;
function xeAutomationPipeHandleIsOpen(const aPipeHandle: THandle): Boolean;
procedure xeAutomationResetPipeHandle(var aPipeHandle: THandle);
function xeAutomationTryPipeClientCall(const aPipeName: string; const aRequestBytes: TBytes; out aResponseBytes: TBytes): Boolean;

implementation

uses
  Classes,
  Generics.Collections,
  JsonDataObjects,
  xeAutomationErrors,
  xeAutomationWireLimits;

const
  xeAutomationPipeNamePrefix = '\\.\pipe\xedit-';
  xeAutomationPipeClientRetryDelayMs = 50;
  xeAutomationPipeClientRetryTimeoutMs = 5000;

type
  TxeClientIO = class
    Handle, Event: THandle;
    Overlapped: TOverlapped;
    Pending, RequestDelivered, WriteIssued: Boolean;
    Buffer: TBytes;
    constructor Create(const AHandle: THandle);
    destructor Destroy; override;
    procedure Prepare;
    function Finish(const ADeadline: UInt64; const APhase: string; var ABytes: Cardinal; const AImmediateError: Cardinal): Cardinal;
    procedure Close;
    function Retired: Boolean;
  end;

var
  RetiredCalls: TObjectList<TxeClientIO>;

function xeAutomationPipeNameForPid(const aPid: Cardinal): string;
begin
  Result := xeAutomationPipeNamePrefix + UIntToStr(aPid);
end;

function xeAutomationPipeHandleIsOpen(const aPipeHandle: THandle): Boolean;
begin
  Result := (aPipeHandle <> 0) and (aPipeHandle <> INVALID_HANDLE_VALUE);
end;

procedure xeAutomationResetPipeHandle(var aPipeHandle: THandle);
begin
  if xeAutomationPipeHandleIsOpen(aPipeHandle) then
    CloseHandle(aPipeHandle);
  aPipeHandle := INVALID_HANDLE_VALUE;
end;

constructor TxeClientIO.Create(const AHandle: THandle);
begin
  inherited Create;
  Handle := AHandle;
  Event := CreateEvent(nil, True, False, nil);
  if Event = 0 then
    RaiseLastOSError;
end;

procedure TxeClientIO.Prepare;
begin
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  Overlapped.hEvent := Event;
  ResetEvent(Event);
  Pending := False;
end;

function TxeClientIO.Finish(const ADeadline: UInt64; const APhase: string; var ABytes: Cardinal; const AImmediateError: Cardinal): Cardinal;
var
  lNow: UInt64;
  lWait: Cardinal;
  lDetails: TJsonObject;
begin
  Result := AImmediateError;
  if Result <> ERROR_IO_PENDING then
    Exit;
  Pending := True;
  lNow := GetTickCount64;
  if lNow >= ADeadline then
    lWait := WAIT_TIMEOUT
  else
    lWait := WaitForSingleObject(Event, Cardinal(ADeadline - lNow));
  if lWait = WAIT_TIMEOUT then begin
    lDetails := TJsonObject.Create;
    try
      lDetails.S['phase'] := APhase;
      lDetails.B['requestDelivered'] := RequestDelivered;
      // A timed-out write can race delivery: absence of write completion does
      // not prove non-execution. Retry only with the exact idempotency payload.
      lDetails.B['executionMayHaveOccurred'] := WriteIssued;
      raise xeAutomationNewError('transport_timeout', 'Automation pipe exchange deadline exceeded', lDetails);
    finally
      lDetails.Free;
    end;
  end;
  if lWait <> WAIT_OBJECT_0 then
    RaiseLastOSError;
  if GetOverlappedResult(Handle, Overlapped, ABytes, False) then
    Result := ERROR_SUCCESS
  else
    Result := GetLastError;
  Pending := False;
end;

procedure TxeClientIO.Close;
begin
  if xeAutomationPipeHandleIsOpen(Handle) then begin
    if Pending then
      CancelIoEx(Handle, @Overlapped);
    xeAutomationResetPipeHandle(Handle);
  end;
end;

function TxeClientIO.Retired: Boolean;
begin
  Result := not Pending or (WaitForSingleObject(Event, 0) = WAIT_OBJECT_0);
end;

destructor TxeClientIO.Destroy;
begin
  Close;
  if Event <> 0 then
    CloseHandle(Event);
  inherited;
end;

function xeAutomationTryPipeClientCall(const aPipeName: string; const aRequestBytes: TBytes; out aResponseBytes: TBytes): Boolean;
var
  lHandle: THandle;
  lIO: TxeClientIO;
  lMode, lError, lTransferred: Cardinal;
  lDeadline: UInt64;
  lStream: TBytesStream;
  lDetails: TJsonObject;
  lPhase: string;
  i: Integer;
begin
  Result := False;
  aResponseBytes := nil;
  if (Length(aRequestBytes) = 0) or (Length(aRequestBytes) > xeAutomationMaxRequestBytes) then
    raise xeAutomationNewError('request_too_large', 'Request must be nonempty and within the advertised UTF-8 byte limit');
  for i := RetiredCalls.Count - 1 downto 0 do
    if RetiredCalls[i].Retired then
      RetiredCalls.Delete(i);
  lDeadline := GetTickCount64 + xeAutomationPipeClientRetryTimeoutMs;
  repeat
    lHandle := CreateFile(PChar(aPipeName), GENERIC_READ or GENERIC_WRITE, 0, nil,
      OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0);
    if xeAutomationPipeHandleIsOpen(lHandle) then
      Break;
    lError := GetLastError;
    if not (lError in [ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY, ERROR_SEM_TIMEOUT]) then
      RaiseLastOSError(lError);
    if GetTickCount64 >= lDeadline then
      Exit(False);
    if lError = ERROR_PIPE_BUSY then
      WaitNamedPipe(PChar(aPipeName), xeAutomationPipeClientRetryDelayMs)
    else
      Sleep(xeAutomationPipeClientRetryDelayMs);
  until False;
  lIO := TxeClientIO.Create(lHandle);
  lPhase := 'write';
  try
    try
    lMode := PIPE_READMODE_MESSAGE;
    if not SetNamedPipeHandleState(lHandle, lMode, nil, nil) then
      RaiseLastOSError;
    // Own the write buffer rather than borrowing caller memory across a canceled
    // operation whose completion may outlive this method.
    lIO.Buffer := Copy(aRequestBytes);
    lIO.Prepare;
    lDeadline := GetTickCount64 + xeAutomationWriteDeadlineMs;
    lIO.WriteIssued := True;
    lError := ERROR_SUCCESS;
    if not WriteFile(lHandle, lIO.Buffer[0], Length(lIO.Buffer), lTransferred, @lIO.Overlapped) then
      lError := GetLastError;
    lError := lIO.Finish(lDeadline, 'write', lTransferred, lError);
    if lError <> ERROR_SUCCESS then
      RaiseLastOSError(lError);
    if lTransferred <> Cardinal(Length(aRequestBytes)) then
      raise Exception.Create('Automation request write was incomplete; execution outcome is uncertain');
    lIO.RequestDelivered := True;
    lPhase := 'read';
    SetLength(lIO.Buffer, 65536);
    lStream := TBytesStream.Create;
    try
      lDeadline := GetTickCount64 + xeAutomationClientResponseDeadlineMs;
      repeat
        if GetTickCount64 >= lDeadline then begin
          lDetails := TJsonObject.Create;
          try
            lDetails.S['phase'] := 'read';
            lDetails.B['requestDelivered'] := True;
            lDetails.B['executionMayHaveOccurred'] := True;
            raise xeAutomationNewError('transport_timeout', 'Automation response read deadline exceeded', lDetails);
          finally
            lDetails.Free;
          end;
        end;
        lIO.Prepare;
        lError := ERROR_SUCCESS;
        if not ReadFile(lHandle, lIO.Buffer[0], Length(lIO.Buffer), lTransferred, @lIO.Overlapped) then
          lError := GetLastError;
        lError := lIO.Finish(lDeadline, 'read', lTransferred, lError);
        if not (lError in [ERROR_SUCCESS, ERROR_MORE_DATA]) then
          RaiseLastOSError(lError);
        if lStream.Size + lTransferred > xeAutomationMaxResponseBytes then
          raise xeAutomationNewError('response_too_large', 'Peer response exceeded the byte limit; command may have executed');
        if lTransferred > 0 then
          lStream.WriteBuffer(lIO.Buffer[0], lTransferred);
      until lError = ERROR_SUCCESS;
      aResponseBytes := Copy(lStream.Bytes, 0, lStream.Size);
      Result := True;
    finally
      lStream.Free;
    end;
    except
      on E: Exception do begin
        if E is ExeAutomationError then
          raise;
        lDetails := TJsonObject.Create;
        try
          lDetails.S['phase'] := lPhase;
          lDetails.B['requestDelivered'] := lIO.RequestDelivered;
          lDetails.B['executionMayHaveOccurred'] := lIO.WriteIssued;
          raise xeAutomationNewError('transport_disconnected', E.Message, lDetails);
        finally
          lDetails.Free;
        end;
      end;
    end;
  finally
    lIO.Close;
    if lIO.Retired then
      lIO.Free
    else
      RetiredCalls.Add(lIO);
  end;
end;

initialization
  RetiredCalls := TObjectList<TxeClientIO>.Create(True);
finalization
  // Preserve any unretired kernel-owned buffers until process teardown.
  for var i := RetiredCalls.Count - 1 downto 0 do
    if RetiredCalls[i].Retired then
      RetiredCalls.Delete(i);
  RetiredCalls.OwnsObjects := False;
  RetiredCalls.Free;
end.
