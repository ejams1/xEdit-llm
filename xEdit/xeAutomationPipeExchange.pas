{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationPipeExchange;

interface

uses
  Windows,
  Classes,
  SysUtils;

type
  TxePipePhase = (xpConnect, xpRead, xpExecute, xpWrite, xpPeerClose, xpDone);
  // One object owns every address referenced by pending kernel I/O. Closing a
  // handle requests cancellation; it does not permit immediate buffer reuse.
  TxeAutomationPipeExchange = class
  private
    FPipe, FEvent: THandle;
    FOverlapped: TOverlapped;
    FPending: Boolean;
    FPhase: TxePipePhase;
    FDeadline: UInt64;
    FBuffer, FResponse: TBytes;
    FRequest: TBytesStream;
    FImmediateBytes, FImmediateError: Cardinal;
    procedure BeginRead;
    procedure PrepareIO;
    function Completed(out ABytes, AError: Cardinal): Boolean;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    procedure Poll;
    function RequestText: string;
    procedure Respond(const AText: string);
    procedure Close;
    function Retired: Boolean;
    property Phase: TxePipePhase read FPhase;
  end;

implementation

uses
  JsonDataObjects,
  xeAutomationWireLimits;

constructor TxeAutomationPipeExchange.Create(const AName: string);
var
  lConnected: Boolean;
begin
  inherited Create;
  FPipe := INVALID_HANDLE_VALUE;
  FEvent := CreateEvent(nil, True, False, nil);
  if FEvent = 0 then
    RaiseLastOSError;
  FRequest := TBytesStream.Create;
  // At 50 ms per timer tick this drains a legal 4 MiB request well within the
  // absolute read deadline, while keeping each main-thread step bounded.
  SetLength(FBuffer, 65536);
  FPipe := CreateNamedPipe(PChar(AName), PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_MESSAGE or PIPE_READMODE_MESSAGE or PIPE_WAIT, 1, 65536, 65536, 0, nil);
  if FPipe = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  FPhase := xpConnect;
  PrepareIO;
  lConnected := ConnectNamedPipe(FPipe, @FOverlapped);
  if not lConnected then begin
    FImmediateError := GetLastError;
    FPending := FImmediateError = ERROR_IO_PENDING;
    if FImmediateError = ERROR_PIPE_CONNECTED then
      FImmediateError := ERROR_SUCCESS;
  end;
end;

procedure TxeAutomationPipeExchange.PrepareIO;
begin
  FillChar(FOverlapped, SizeOf(FOverlapped), 0);
  FOverlapped.hEvent := FEvent;
  ResetEvent(FEvent);
  FImmediateBytes := 0;
  FImmediateError := ERROR_SUCCESS;
  FPending := False;
end;

function TxeAutomationPipeExchange.Completed(out ABytes, AError: Cardinal): Boolean;
begin
  ABytes := FImmediateBytes;
  AError := FImmediateError;
  if not FPending then
    Exit(True);
  if GetOverlappedResult(FPipe, FOverlapped, ABytes, False) then
    AError := ERROR_SUCCESS
  else begin
    AError := GetLastError;
    if AError = ERROR_IO_INCOMPLETE then
      Exit(False);
  end;
  FPending := False;
  Result := True;
end;

procedure TxeAutomationPipeExchange.BeginRead;
begin
  PrepareIO;
  if not ReadFile(FPipe, FBuffer[0], Length(FBuffer), FImmediateBytes, @FOverlapped) then begin
    FImmediateError := GetLastError;
    FPending := FImmediateError = ERROR_IO_PENDING;
  end;
end;

procedure TxeAutomationPipeExchange.Poll;
var
  lBytes, lError: Cardinal;
  lResponse: TJsonObject;
begin
  if FPhase in [xpExecute, xpDone] then
    Exit;
  if (FPhase <> xpConnect) and (GetTickCount64 >= FDeadline) then begin
    Close;
    Exit;
  end;
  if not Completed(lBytes, lError) then
    Exit;
  case FPhase of
    xpConnect: begin
      if lError <> ERROR_SUCCESS then begin
        Close;
        Exit;
      end;
      FPhase := xpRead;
      FDeadline := GetTickCount64 + xeAutomationReadDeadlineMs;
      BeginRead;
    end;
    xpRead: begin
      if not (lError in [ERROR_SUCCESS, ERROR_MORE_DATA]) or (lBytes = 0) then begin
        Close;
        Exit;
      end;
      if FRequest.Size + lBytes > xeAutomationMaxRequestBytes then begin
        lResponse := TJsonObject.Create;
        try
          lResponse.B['ok'] := False;
          lResponse.O['error'].S['code'] := 'request_too_large';
          lResponse.O['error'].S['message'] := 'Request exceeds the advertised UTF-8 byte limit';
          lResponse.O['error'].O['details'].I['maxBytes'] := xeAutomationMaxRequestBytes;
          lResponse.O['error'].O['details'].B['executed'] := False;
          Respond(lResponse.ToJSON(False));
        finally
          lResponse.Free;
        end;
        Exit;
      end;
      FRequest.WriteBuffer(FBuffer[0], lBytes);
      if lError = ERROR_MORE_DATA then
        BeginRead
      else
        FPhase := xpExecute;
    end;
    xpWrite: begin
      if (lError <> ERROR_SUCCESS) or (lBytes <> Cardinal(Length(FResponse))) then begin
        Close;
        Exit;
      end;
      // The client closes after consuming its one response. Observe close with
      // overlapped I/O instead of an unbounded FlushFileBuffers on the UI thread.
      FPhase := xpPeerClose;
      FDeadline := GetTickCount64 + xeAutomationPeerCloseDeadlineMs;
      BeginRead;
    end;
    xpPeerClose: Close; // Any second message is rejected without dispatch.
  end;
end;

function TxeAutomationPipeExchange.RequestText: string;
var
  lLength: Integer;
begin
  // Invalid UTF-8 is rejected, ensuring replay's exact-text identity cannot
  // collapse distinct malformed byte payloads through replacement characters.
  lLength := MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
    PAnsiChar(FRequest.Memory), Integer(FRequest.Size), nil, 0);
  if lLength = 0 then
    RaiseLastOSError;
  SetLength(Result, lLength);
  if MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
    PAnsiChar(FRequest.Memory), Integer(FRequest.Size), PChar(Result), lLength) <> lLength then
    RaiseLastOSError;
end;

procedure TxeAutomationPipeExchange.Respond(const AText: string);
begin
  FResponse := TEncoding.UTF8.GetBytes(AText);
  if Length(FResponse) > xeAutomationMaxResponseBytes then
    raise Exception.Create('Host response was not bounded before pipe delivery');
  FPhase := xpWrite;
  FDeadline := GetTickCount64 + xeAutomationWriteDeadlineMs;
  PrepareIO;
  // One WriteFile is one message. Receiver-side ERROR_MORE_DATA chunking keeps
  // message framing unchanged even when the response exceeds pipe buffer size.
  if not WriteFile(FPipe, FResponse[0], Length(FResponse), FImmediateBytes, @FOverlapped) then begin
    FImmediateError := GetLastError;
    FPending := FImmediateError = ERROR_IO_PENDING;
  end;
end;

procedure TxeAutomationPipeExchange.Close;
begin
  FPhase := xpDone;
  if FPipe <> INVALID_HANDLE_VALUE then begin
    if FPending then
      CancelIoEx(FPipe, @FOverlapped);
    CloseHandle(FPipe);
    FPipe := INVALID_HANDLE_VALUE;
  end;
end;

function TxeAutomationPipeExchange.Retired: Boolean;
begin
  // Even after close, the completion event and all buffers remain alive until
  // the canceled operation signals. No wait runs on the main thread.
  Result := not FPending or (WaitForSingleObject(FEvent, 0) = WAIT_OBJECT_0);
end;

destructor TxeAutomationPipeExchange.Destroy;
begin
  Close;
  FRequest.Free;
  if FEvent <> 0 then
    CloseHandle(FEvent);
  inherited;
end;

end.
