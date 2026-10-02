{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationRecordComparison;

interface

uses
  wbInterface;

function xeAutomationRecordIsIdenticalToMaster(const ARecord: IwbMainRecord): Boolean;

implementation

uses
  Classes,
  SysUtils;

function xeAutomationRecordIsIdenticalToMaster(const ARecord: IwbMainRecord): Boolean;
var
  lMaster: IwbMainRecord;
  lLeftStream, lRightStream: TMemoryStream;
  lLeftFile, lRightFile, lRightMaster: IwbFile;
  i: Integer;
begin
  Result := False;
  if not Assigned(ARecord) then
    Exit;
  lMaster := ARecord.MasterOrSelf;
  if not Assigned(lMaster) or lMaster.Equals(ARecord) or lMaster.IsInjected then
    Exit;

  // Flags are user data, including unknown bits. Never let a payload-only or
  // cached conflict comparison erase a flag-only override.
  if (lMaster.Signature <> ARecord.Signature) or
     (lMaster.Flags._Flags <> ARecord.Flags._Flags) then
    Exit;

  Result := lMaster.ContentEquals(ARecord);
  if Result then
    Exit;
  // A negative native comparison is authoritative for unchanged records.
  // ContentEquals refuses modified records; only those need a serialization
  // fallback. ConflictThis can be stale after an edit and is not a fallback.
  if not (lMaster.Modified or ARecord.Modified) then
    Exit;

  // Identical file-local reference bytes can name different records when the
  // master tables differ. Require the source's complete index mapping (including
  // its self slot) to be the same before trusting serialized bytes. Complex
  // module slots need a separate mapping proof and conservatively stay retained.
  if wbComplexFileFileID then
    Exit;
  lLeftFile := lMaster._File;
  lRightFile := ARecord._File;
  if not Assigned(lLeftFile) or not Assigned(lRightFile) or
     (lLeftFile.MasterCount[True] > lRightFile.MasterCount[True]) then
    Exit;
  for i := 0 to lLeftFile.MasterCount[True] do begin
    if i = lRightFile.MasterCount[True] then
      lRightMaster := lRightFile
    else
      lRightMaster := lRightFile.Masters[i, True];
    if i = lLeftFile.MasterCount[True] then begin
      if not lLeftFile.Equals(lRightMaster) then
        Exit;
    end else if not lLeftFile.Masters[i, True].Equals(lRightMaster) then
      Exit;
  end;

  lLeftStream := TMemoryStream.Create;
  try
    lRightStream := TMemoryStream.Create;
    try
      // Compare every byte, including the header, without resetting dirtiness.
      // This is deliberately conservative when file-local IDs, compression or
      // version-control metadata differ: uncertain overrides must be retained.
      lMaster.WriteToStream(lLeftStream, rmNo);
      ARecord.WriteToStream(lRightStream, rmNo);
      Result := (lLeftStream.Size > 0) and (lLeftStream.Size = lRightStream.Size) and
        CompareMem(lLeftStream.Memory, lRightStream.Memory, lLeftStream.Size);
    finally
      lRightStream.Free;
    end;
  finally
    lLeftStream.Free;
  end;
end;

end.
