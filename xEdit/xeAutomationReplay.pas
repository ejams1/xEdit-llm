{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationReplay;

interface

procedure xeAutomationReplayBeginSession;
procedure xeAutomationReplayEndSession;
function xeAutomationReplaySessionId: string;
function xeAutomationReplayReserve(const AKey, ARequest: string; out AResponse: string; out ASucceeded: Boolean): Boolean;
procedure xeAutomationReplayComplete(const AKey, AResponse: string; const ASucceeded: Boolean);

implementation

uses
  SysUtils,
  Generics.Collections,
  Generics.Defaults,
  xeAutomationErrors,
  xeAutomationWireLimits;

type
  TxeReplayEntry = class
    Request, Response: string;
    Completed, Succeeded: Boolean;
    RetainedBytes: Int64;
  end;

var
  Entries: TObjectDictionary<string, TxeReplayEntry>;
  Order: TQueue<string>;
  RetainedBytes: Int64;
  SessionId: string;

procedure xeAutomationReplayEndSession;
begin
  FreeAndNil(Entries);
  FreeAndNil(Order);
  RetainedBytes := 0;
  SessionId := '';
end;

procedure xeAutomationReplayBeginSession;
var
  lId: TGUID;
begin
  xeAutomationReplayEndSession;
  CreateGUID(lId);
  SessionId := GUIDToString(lId);
  Entries := TObjectDictionary<string, TxeReplayEntry>.Create([doOwnsValues], TStringComparer.Ordinal);
  Order := TQueue<string>.Create;
end;

function xeAutomationReplaySessionId: string;
begin
  Result := SessionId;
end;

function xeAutomationReplayReserve(const AKey, ARequest: string; out AResponse: string; out ASucceeded: Boolean): Boolean;
var
  lEntry, lOld: TxeReplayEntry;
  lBytes: Int64;
  lOldKey: string;
begin
  Result := False;
  AResponse := '';
  ASucceeded := False;
  if not Assigned(Entries) then
    raise xeAutomationNewError('idempotency_unavailable', 'Idempotency replay requires a loaded daemon session');
  if Entries.TryGetValue(AKey, lEntry) then begin
    // Exact text after strict UTF-8 decoding: whitespace/property ordering and
    // correlation changes intentionally conflict. Keys are ordinal/case-sensitive.
    if lEntry.Request <> ARequest then
      raise xeAutomationNewError('idempotency_conflict', 'Key was already used with a different request payload');
    if not lEntry.Completed then
      raise xeAutomationNewError('idempotency_in_progress', 'Key is currently executing');
    AResponse := lEntry.Response;
    ASucceeded := lEntry.Succeeded;
    Exit(True);
  end;
  // Reserve the maximum response budget before execution. An outcome can always
  // be retained even when it is a partial failure or an oversized-response error.
  lBytes := Int64(TEncoding.UTF8.GetByteCount(ARequest)) + xeAutomationMaxResponseBytes;
  while (Entries.Count >= xeAutomationReplayMaxEntries) or
        (RetainedBytes + lBytes > xeAutomationReplayMaxBytes) do begin
    if Order.Count = 0 then
      raise xeAutomationNewError('idempotency_capacity', 'Replay capacity is occupied by executing requests');
    lOldKey := Order.Peek;
    lOld := Entries[lOldKey];
    if not lOld.Completed then
      raise xeAutomationNewError('idempotency_capacity', 'Replay capacity is occupied by executing requests');
    Order.Dequeue;
    Dec(RetainedBytes, lOld.RetainedBytes);
    Entries.Remove(lOldKey);
  end;
  lEntry := TxeReplayEntry.Create;
  lEntry.Request := ARequest;
  lEntry.RetainedBytes := lBytes;
  Entries.Add(AKey, lEntry);
  Order.Enqueue(AKey);
  Inc(RetainedBytes, lBytes);
end;

procedure xeAutomationReplayComplete(const AKey, AResponse: string; const ASucceeded: Boolean);
var
  lEntry: TxeReplayEntry;
begin
  if not Assigned(Entries) or not Entries.TryGetValue(AKey, lEntry) then
    Exit;
  Dec(RetainedBytes, lEntry.RetainedBytes);
  lEntry.Response := AResponse;
  lEntry.Succeeded := ASucceeded;
  lEntry.Completed := True;
  lEntry.RetainedBytes := Int64(TEncoding.UTF8.GetByteCount(lEntry.Request)) + TEncoding.UTF8.GetByteCount(AResponse);
  Inc(RetainedBytes, lEntry.RetainedBytes);
end;

finalization
  xeAutomationReplayEndSession;
end.
