{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationMutationAudit;

interface

uses
  SysUtils,
  JsonDataObjects,
  wbInterface,
  xeAutomationErrors;

type
  TxeAutomationFileGeneration = record
    FileRef: IwbFile;
    Generation: Integer;
  end;
  TxeAutomationMutationSnapshot = record
    Generation: UInt64;
    Files: TArray<TxeAutomationFileGeneration>;
  end;

function xeAutomationCaptureMutationSnapshot: TxeAutomationMutationSnapshot;
procedure xeAutomationWriteMutationAudit(const ATarget: TJsonObject; const ABefore: TxeAutomationMutationSnapshot);
function xeAutomationMutationFailure(const AError: Exception; const ADefaultCode, APhase: string;
  const ABefore: TxeAutomationMutationSnapshot; const ACompletedSteps: TArray<string>): ExeAutomationError;

implementation

uses
  wbLoadOrder,
  xeAutomationDataLookup;

function xeAutomationCaptureMutationSnapshot: TxeAutomationMutationSnapshot;
var
  lModules: TwbModuleInfos;
  lFile: IwbFile;
  i, lIndex: Integer;
begin
  Result.Generation := wbGlobalModifedGeneration;
  Result.Files := nil;
  lModules := wbModulesByLoadOrder;
  for i := Low(lModules) to High(lModules) do begin
    lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
    if not Assigned(lFile) then
      Continue;
    lIndex := Length(Result.Files);
    SetLength(Result.Files, lIndex + 1);
    Result.Files[lIndex].FileRef := lFile;
    Result.Files[lIndex].Generation := lFile.ElementGeneration;
  end;
end;

procedure xeAutomationWriteMutationAudit(const ATarget: TJsonObject; const ABefore: TxeAutomationMutationSnapshot);
var
  lAfter: TxeAutomationMutationSnapshot;
  lChanged, lFound: Boolean;
  i, j: Integer;
begin
  lAfter := xeAutomationCaptureMutationSnapshot;
  ATarget.S['generationBefore'] := UIntToStr(ABefore.Generation);
  ATarget.S['generationAfter'] := UIntToStr(lAfter.Generation);
  ATarget.B['mutationsObserved'] := ABefore.Generation <> lAfter.Generation;
  ATarget.S['observation'] := 'native-modification-generations';
  ATarget.A['affectedFiles'].Clear;
  for i := Low(lAfter.Files) to High(lAfter.Files) do begin
    lChanged := True;
    for j := Low(ABefore.Files) to High(ABefore.Files) do
      if ABefore.Files[j].FileRef.Equals(lAfter.Files[i].FileRef) then begin
        lChanged := ABefore.Files[j].Generation <> lAfter.Files[i].Generation;
        Break;
      end;
    if lChanged then
      ATarget.A['affectedFiles'].Add(lAfter.Files[i].FileRef.FileName);
  end;
  for i := Low(ABefore.Files) to High(ABefore.Files) do begin
    lFound := False;
    for j := Low(lAfter.Files) to High(lAfter.Files) do
      if ABefore.Files[i].FileRef.Equals(lAfter.Files[j].FileRef) then begin
        lFound := True;
        Break;
      end;
    if not lFound then
      ATarget.A['affectedFiles'].Add(ABefore.Files[i].FileRef.FileName);
  end;
end;

function xeAutomationMutationFailure(const AError: Exception; const ADefaultCode, APhase: string;
  const ABefore: TxeAutomationMutationSnapshot; const ACompletedSteps: TArray<string>): ExeAutomationError;
var
  lDetails: TJsonObject;
  lCode, lStep: string;
begin
  lCode := ADefaultCode;
  lDetails := TJsonObject.Create;
  try
    if AError is ExeAutomationError then begin
      lCode := ExeAutomationError(AError).Code;
      if Assigned(ExeAutomationError(AError).Details) then
        lDetails.Assign(ExeAutomationError(AError).Details);
    end;
    lDetails.S['phase'] := APhase;
    xeAutomationWriteMutationAudit(lDetails.O['mutationState'], ABefore);
    lDetails.B['partial'] := lDetails.O['mutationState'].B['mutationsObserved'];
    lDetails.B['partialKnown'] := True;
    lDetails.B['rollbackComplete'] := False;
    lDetails.S['remainingState'] := 'Inspect affected files; in-memory mutations require explicit save or discard';
    lDetails.A['completedSteps'].Clear;
    for lStep in ACompletedSteps do
      lDetails.A['completedSteps'].Add(lStep);
    Result := xeAutomationNewError(lCode, AError.Message, lDetails);
  finally
    lDetails.Free;
  end;
end;

end.
