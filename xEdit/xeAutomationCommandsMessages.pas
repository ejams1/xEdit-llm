{ This Source Code Form is subject to the Mozilla Public License, v. 2.0.
  https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsMessages;
interface
procedure xeAutomationCaptureMessage(const Text: string);
implementation
uses SysUtils, Classes, Math, JsonDataObjects, xeAutomationRegistry,
  xeAutomationErrors, xeAutomationDataLookup, xeAutomationObjectModel,
  xeAutomationMutationPolicy, xeAutomationExternalIO, wbInterface,
  xeLogAnalyzerForm;
const Capacity = 1024; CharacterBudget = 524288; LineLimit = 8192;
type TMessage = record Text: string; OriginalLength: Integer; end;
var Messages: array[0..Capacity-1] of TMessage;
  First, Next: UInt64; Characters: Integer; Epoch: string;

procedure EnsureEpoch;
var ID: TGUID;
begin
  if Epoch <> '' then Exit;
  CreateGUID(ID); Epoch := GUIDToString(ID); First := 1; Next := 1;
end;

procedure xeAutomationCaptureMessage(const Text: string);
var Index: Integer;
begin
  // Called on the native main-thread AddMessage seam, including posted messages
  // once delivered. UI clears and script-local capture do not reset this stream.
  EnsureEpoch;
  while (Next - First >= Capacity) or (Characters + Min(Length(Text), LineLimit) > CharacterBudget) do begin
    Index := First mod Capacity; Dec(Characters, Length(Messages[Index].Text));
    Messages[Index].Text := ''; Inc(First);
  end;
  Index := Next mod Capacity;
  Messages[Index].Text := Copy(Text, 1, LineLimit);
  Messages[Index].OriginalLength := Length(Text);
  Inc(Characters, Length(Messages[Index].Text)); Inc(Next);
end;

function ReadMessages(const Args: TJsonObject): TJsonObject;
var Cursor: string; Parts: TArray<string>; Start, Stop, Seq: UInt64;
  Limit, Index, PageCharacters: Integer; Row: TJsonObject;
begin
  EnsureEpoch; Limit := xeAutomationReadChildrenLimitArg(Args, 'limit', 100);
  if Limit > 200 then raise xeAutomationInvalidRequest('Message limit must be 1..200');
  Start := First; Stop := Next;
  Cursor := xeAutomationReadStringArg(Args, 'cursor');
  if Cursor <> '' then begin
    Parts := Cursor.Split(['|']);
    if (Length(Parts) <> 3) or (Parts[0] <> Epoch) or
      not TryStrToUInt64(Parts[1], Start) or not TryStrToUInt64(Parts[2], Stop) then
      raise xeAutomationNewError('message_cursor_invalid', 'Cursor must belong to this session');
    if (Start < First) or (Start > Stop) or (Stop > Next) then
      raise xeAutomationNewError('message_cursor_expired', 'Retained message range expired; restart from earliest available');
  end;
  Result := TJsonObject.Create;
  Result.S['epoch'] := Epoch; Result.S['firstAvailable'] := UIntToStr(First);
  Result.S['snapshotEnd'] := UIntToStr(Stop); Result.B['earlierMessagesEvicted'] := First > 1;
  Result.S['scope'] := 'full-session AddMessage lines delivered so far; bounded retained window';
  Result.I['retainedLineLimit'] := Capacity; Result.I['lineCharacterLimit'] := LineLimit;
  Result.A['messages']; PageCharacters := 0; Seq := Start;
  while (Seq < Stop) and (Result.A['messages'].Count < Limit) do begin
    Index := Seq mod Capacity;
    if PageCharacters + Length(Messages[Index].Text) > 65536 then Break;
    Row := Result.A['messages'].AddObject;
    Row.S['sequence'] := UIntToStr(Seq); Row.S['text'] := Messages[Index].Text;
    Row.I['originalCharacters'] := Messages[Index].OriginalLength;
    Row.B['truncated'] := Messages[Index].OriginalLength > Length(Messages[Index].Text);
    Inc(PageCharacters, Length(Messages[Index].Text)); Inc(Seq);
  end;
  Result.B['complete'] := Seq = Stop;
  if Seq < Stop then Result.S['nextCursor'] := Epoch + '|' + UIntToStr(Seq) + '|' + UIntToStr(Stop);
  Result.S['nextSequence'] := UIntToStr(Seq); Result.I['count'] := Result.A['messages'].Count;
end;

function ExportMessages(const Args: TJsonObject): TJsonObject;
var Root, Name, Denied: string; Dry, Specified, Overwrite: Boolean;
  Lines: TStringList; Stream: TStringStream; Seq, Stop: UInt64; Index: Integer;
begin
  EnsureEpoch;
  Root := xeAutomationExternalRoot(xeAutomationRequireStringArg(Args, 'outputDirectory'));
  Name := xeAutomationReadStringArg(Args, 'fileName'); if Name = '' then Name := 'xedit-messages.txt';
  if (Length(Name) > 80) or (Name <> ExtractFileName(Name)) or (Pos(':', Name) > 0) or
    not SameText(ExtractFileExt(Name), '.txt') then raise xeAutomationInvalidRequest('fileName must be a plain .txt basename <=80 characters');
  Dry := xeAutomationReadBooleanArg(Args, 'dryRun', Specified); if not Specified then Dry := True;
  Overwrite := xeAutomationReadBooleanArg(Args, 'overwrite', Specified);
  if not Dry and not xeAutomationMutationPolicyConsentSatisfied(Denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('messages.export', 'external-output', Denied));
  Lines := TStringList.Create;
  try
    Result := TJsonObject.Create;
    try
      Stop := Next; Seq := First;
      Result.B['dryRun'] := Dry; Result.B['written'] := False;
      Result.S['outputPath'] := Root + Name; Result.S['epoch'] := Epoch;
      Result.S['firstSequence'] := UIntToStr(First); Result.S['snapshotEnd'] := UIntToStr(Stop);
      Result.B['earlierMessagesEvicted'] := First > 1; Result.B['truncatedLines'] := False;
      while Seq < Stop do begin
        Index := Seq mod Capacity; Lines.Add(Messages[Index].Text);
        Result.B['truncatedLines'] := Result.B['truncatedLines'] or (Length(Messages[Index].Text) <> Messages[Index].OriginalLength);
        Inc(Seq);
      end;
      Stream := TStringStream.Create(Lines.Text, TEncoding.UTF8);
      try
        Result.I['lines'] := Lines.Count; Result.L['bytes'] := Stream.Size;
        Result.S['persistence'] := 'immediate external UTF-8 snapshot; plugin save independent';
        if not Dry then begin xeAutomationAtomicWrite(Root + Name, Stream, Overwrite); Result.B['written'] := True; end;
      finally Stream.Free; end;
    except Result.Free; raise; end;
  finally Lines.Free; end;
end;

function AnalyzeLog(const Args: TJsonObject): TJsonObject;
var Root, Name, Kind, EncodingName, Text: string; LogType: TLogType;
  Input: TFileStream; Lines: TStringList; Bytes, RoundTrip: TBytes;
  Encoding: TEncoding; i: Integer;
begin
  Kind := xeAutomationRequireStringArg(Args, 'format');
  if SameText(Kind, 'papyrus') then begin
    if not wbIsSkyrim then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Native Papyrus log attribution is available in Skyrim-family modes');
    LogType := ltTES5Papyrus;
  end else if SameText(Kind, 'xse-profiler') then begin
    if not (wbGameMode in [gmTES4, gmFO3, gmFNV]) then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Native xSE profiler attribution requires TES4/FO3/FNV');
    LogType := ltTES4RuntimeScriptProfiler;
  end else raise xeAutomationInvalidRequest('format must be papyrus or xse-profiler');
  Root := xeAutomationExternalRoot(xeAutomationRequireStringArg(Args, 'inputDirectory'));
  Name := xeAutomationRequireStringArg(Args, 'fileName');
  if (Length(Name) > 80) or (Name <> ExtractFileName(Name)) or (Pos(':', Name) > 0) or
    not (SameText(ExtractFileExt(Name), '.log') or SameText(ExtractFileExt(Name), '.txt')) then
    raise xeAutomationInvalidRequest('fileName must be a plain .log/.txt basename <=80 characters');
  EncodingName := xeAutomationReadStringArg(Args, 'encoding');
  if (EncodingName = '') or SameText(EncodingName, 'utf-8') then Encoding := TEncoding.UTF8
  else if SameText(EncodingName, 'native-ansi') then Encoding := TEncoding.Default
  else raise xeAutomationInvalidRequest('encoding must be utf-8 or native-ansi');
  // Capture once with write sharing denied. Validate exact bytes and total size
  // before native parsing; no default game/log directory or modal picker is used.
  Input := TFileStream.Create(Root + Name, fmOpenRead or fmShareDenyWrite);
  try
    if Input.Size > 262144 then raise xeAutomationNewError('log_capacity', 'Native log snapshot is limited to 256 KiB');
    SetLength(Bytes, Input.Size);
    if Length(Bytes) > 0 then Input.ReadBuffer(Bytes[0], Length(Bytes));
  finally Input.Free; end;
  Text := Encoding.GetString(Bytes); RoundTrip := Encoding.GetBytes(Text);
  if Length(Bytes) <> Length(RoundTrip) then raise xeAutomationInvalidRequest('Log bytes are not valid in the selected encoding');
  for i := Low(Bytes) to High(Bytes) do if Bytes[i] <> RoundTrip[i] then
    raise xeAutomationInvalidRequest('Log bytes are not valid in the selected encoding');
  if (Length(Text) > 0) and (Text[1] = #$FEFF) then Delete(Text,1,1);
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    if Lines.Count > 10000 then raise xeAutomationNewError('log_capacity', 'Native log snapshot is limited to 10000 lines');
    Result := xeAutomationAnalyzeLog(Lines, LogType);
    Result.S['inputPath'] := Root + Name; Result.I['inputBytes'] := Length(Bytes);
    Result.S['format'] := Kind; Result.S['encoding'] := Encoding.EncodingName;
    Result.S['persistence'] := 'read-only captured external log and native record attribution; no plugin save';
  finally Lines.Free; end;
end;

initialization
  xeAutomationRegisterCommand('messages.read', ReadMessages);
  xeAutomationRegisterCommand('messages.export', ExportMessages);
  xeAutomationRegisterCommand('logs.analyze', AnalyzeLog);
end.
