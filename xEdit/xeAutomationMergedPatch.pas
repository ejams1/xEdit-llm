{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationMergedPatch;

interface

uses JsonDataObjects;

function xeAutomationMergedPatchCommand(const AArgs: TJsonObject): TJsonObject;

implementation

uses
  Classes, SysUtils, System.Generics.Collections, wbInterface, wbImplementation,
  wbLoadOrder, xeAutomationDataLookup, xeAutomationErrors, xeAutomationObjectModel,
  xeAutomationMutationPolicy, xeAutomationMutationAudit, xeAutomationRecordQueries;

type
  TxeMergePlan = class
    Master, Winner: IwbMainRecord;
    Names, Counts: TArray<string>;
    Lists: TArray<TStringList>;
    Changed: TArray<Boolean>;
    KeepAlive: TArray<IwbContainerElementRef>;
    Outcome: string;
    destructor Destroy; override;
    function BuildList(const AElement: IwbElement; AAsSet, AOrdered: Boolean;
      var ABudget: Integer): TStringList;
    procedure Build(var ABudget: Integer);
  end;

destructor TxeMergePlan.Destroy;
var i: Integer;
begin
  for i := Low(Lists) to High(Lists) do Lists[i].Free;
  inherited;
end;

function xeMergeListsEqual(ALeft, ARight: TStringList; APrefix: Boolean = False): Boolean;
var i: Integer;
begin
  if APrefix then Result := ALeft.Count <= ARight.Count
  else Result := ALeft.Count = ARight.Count;
  if Result then
    for i := 0 to ALeft.Count - 1 do
      if not SameText(ALeft[i], ARight[i]) then Exit(False);
end;

procedure xeMergeUpdate(ALeft, ARight, ATarget: TStringList);
var lLeft, lRight, lIndex: Integer;
begin
  // Port the native list delta, including deletions and payload replacement for
  // retained keys. Unioning winners loses changes from independent overrides.
  lLeft := 0;
  lRight := 0;
  while (lLeft < ALeft.Count) and (lRight < ARight.Count) do
    case CompareText(ALeft[lLeft], ARight[lRight]) of
      Low(Integer)..-1: begin
        if ATarget.Find(ALeft[lLeft], lIndex) then ATarget.Delete(lIndex);
        Inc(lLeft);
      end;
      0: begin
        if ATarget.Find(ALeft[lLeft], lIndex) then ATarget.Objects[lIndex] := ARight.Objects[lRight];
        Inc(lLeft);
        Inc(lRight);
      end;
      1..High(Integer): begin
        if not ATarget.Find(ARight[lRight], lIndex) then ATarget.AddObject(ARight[lRight], ARight.Objects[lRight]);
        Inc(lRight);
      end;
    end;
  while lLeft < ALeft.Count do begin
    if ATarget.Find(ALeft[lLeft], lIndex) then ATarget.Delete(lIndex);
    Inc(lLeft);
  end;
  while lRight < ARight.Count do begin
    if not ATarget.Find(ARight[lRight], lIndex) then ATarget.AddObject(ARight[lRight], ARight.Objects[lRight]);
    Inc(lRight);
  end;
end;

function TxeMergePlan.BuildList(const AElement: IwbElement; AAsSet, AOrdered: Boolean;
  var ABudget: Integer): TStringList;
var
  lEntries, lEntry: IwbContainerElementRef;
  lLast, lKey: string;
  i, lCount: Integer;
begin
  Result := TStringList.Create;
  try
    if AAsSet and not AOrdered then begin
      Result.Sorted := True;
      Result.Duplicates := dupIgnore;
    end;
    if not Supports(AElement, IwbContainerElementRef, lEntries) then begin
      Result.Sorted := not AOrdered;
      Exit;
    end;
    if lEntries.ElementCount > 512 then
      raise xeAutomationNewError('patch_capacity', 'Merge lists are limited to 512 entries');
    Inc(ABudget, lEntries.ElementCount);
    if ABudget > 16384 then
      raise xeAutomationNewError('patch_capacity', 'Merge plan exceeds 16384 inspected entries');
    for i := 0 to lEntries.ElementCount - 1 do begin
      if not Supports(lEntries.Elements[i], IwbContainerElementRef, lEntry) then
        raise xeAutomationInvalidTarget('Native merge entry has no container sort key');
      // TStringList stores native interface pointers, as the GUI does. Hold
      // their interfaces separately until every plan and copy is finished.
      SetLength(KeepAlive, Length(KeepAlive) + 1);
      KeepAlive[High(KeepAlive)] := lEntry;
      lKey := lEntry.DisplaySortKey[True];
      if Length(lKey) > 4096 then raise xeAutomationNewError('patch_capacity', 'Merge sort key exceeds 4096 characters');
      Result.AddObject(lKey, TObject(Pointer(lEntry)));
    end;
    if not AAsSet and not AOrdered then begin
      Result.Sort;
      lLast := '';
      lCount := 0;
      for i := 0 to Result.Count - 1 do begin
        if Result[i] = lLast then Inc(lCount)
        else begin lCount := 0; lLast := Result[i]; end;
        Result[i] := Result[i] + '#' + IntToHex(lCount, 4);
      end;
      Result.Sorted := True;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TxeMergePlan.Build(var ABudget: Integer);
var
  lCurrent, lBaseline: IwbMainRecord;
  lMasters: TDynMainRecords;
  lCurrentList, lMasterList, lWinningList: TStringList;
  lSortable: IwbSortableContainer;
  lOrdered, lAsSet: Boolean;
  i, j, k, n: Integer;
begin
  Outcome := 'unchanged';
  Winner := Master.WinningOverride;
  if Master.OverrideCount < 2 then begin Outcome := 'insufficient-overrides'; Exit; end;
  if Master.OverrideCount > 128 then raise xeAutomationNewError('patch_capacity', 'Merge allows at most 128 overrides per record');
  if Winner.IsDeleted then begin Outcome := 'deleted-winner'; Exit; end;
  if (Master.Signature = 'LVLI') or (Master.Signature = 'LVLC') or
     (Master.Signature = 'LVLN') or (Master.Signature = 'LVSP') then begin
    Names := ['Leveled List Entries']; Counts := ['LLCT'];
  end else if Master.Signature = 'CONT' then begin Names := ['Items']; Counts := ['COCT']; end
  else if Master.Signature = 'FACT' then Names := ['Relations']
  else if Master.Signature = 'RACE' then begin
    Names := ['HNAM - Hairs', 'ENAM - Eyes', 'Actor Effects']; Counts := ['', '', 'SPCT'];
  end else if Master.Signature = 'FLST' then Names := ['FormIDs']
  else if Master.Signature = 'CREA' then begin Names := ['Items', 'Factions']; Counts := ['COCT']; end
  else if Master.Signature = 'NPC_' then Names := ['Items', 'Factions', 'Head Parts', 'Actor Effects']
  else if (Master.Signature = 'DIAL') and (wbGameMode = gmFNV) then Names := ['Added Quests'];
  if Length(Names) = 0 then raise xeAutomationInvalidTarget('Selected record signature has no supported native merge lists');
  SetLength(Lists, Length(Names));
  SetLength(Changed, Length(Names));
  lAsSet := Master.Signature = 'FLST';
  for n := Low(Names) to High(Names) do begin
    lOrdered := False;
    if Supports(Master.ElementByName[Names[n]], IwbSortableContainer, lSortable) and not lSortable.Sorted then begin
      lOrdered := SameText(Copy(Master.EditorID, Length(Master.EditorID) - 10, 11), 'OrderedList');
      if not lOrdered then Continue;
    end;
    Lists[n] := BuildList(Master.ElementByName[Names[n]], lAsSet, lOrdered, ABudget);
    for i := 0 to Master.OverrideCount - 1 do begin
      lCurrent := Master.Overrides[i];
      if lCurrent.IsDeleted then begin Outcome := 'deleted-participant'; Exit; end;
      // Native merge uses each override's declared-master baseline, not the
      // immediately preceding load-order override. Preserve sibling deltas.
      lMasters := lCurrent.MasterRecordsFromMasterFilesAndSelf;
      lBaseline := nil;
      for k := High(lMasters) downto Low(lMasters) do
        if not lCurrent.Equals(lMasters[k]) then begin lBaseline := lMasters[k]; Break; end;
      if not Assigned(lBaseline) then raise xeAutomationInvalidTarget('Merge override has no declared-master baseline');
      lCurrentList := BuildList(lCurrent.ElementByName[Names[n]], lAsSet, lOrdered, ABudget);
      try
        lMasterList := BuildList(lBaseline.ElementByName[Names[n]], lAsSet, lOrdered, ABudget);
        try
          if lOrdered then begin
            if not xeMergeListsEqual(lMasterList, lCurrentList, True) then begin
              Outcome := 'faulty-ordered-list';
              Exit;
            end;
            for j := lMasterList.Count to lCurrentList.Count - 1 do
              Lists[n].AddObject(lCurrentList[j], lCurrentList.Objects[j]);
          end else xeMergeUpdate(lMasterList, lCurrentList, Lists[n]);
        finally lMasterList.Free; end;
      finally lCurrentList.Free; end;
    end;
    if Lists[n].Count > 512 then raise xeAutomationNewError('patch_capacity', 'Merged list exceeds 512 entries');
    if (n <= High(Counts)) and (Counts[n] = 'LLCT') and (wbGameMode <> gmTES4) and (Lists[n].Count > 255) then
      raise xeAutomationNewError('patch_capacity', 'Merged leveled list exceeds 8-bit LLCT capacity');
    lWinningList := BuildList(Winner.ElementByName[Names[n]], lAsSet, lOrdered, ABudget);
    try Changed[n] := not xeMergeListsEqual(Lists[n], lWinningList);
    finally lWinningList.Free; end;
    if Changed[n] then Outcome := 'planned';
  end;
end;

function xeAutomationMergedPatchCommand(const AArgs: TJsonObject): TJsonObject;
var
  lPlans: TObjectList<TxeMergePlan>;
  lPlan: TxeMergePlan;
  lTarget, lFile: IwbFile;
  lSelected, lRecord: IwbMainRecord;
  lLocator: TxeAutomationLocator;
  lModules: TwbModuleInfos;
  lMasters, lSeen: TStringList;
  lEntries: IwbContainerElementRef;
  lCount: IwbElement;
  lSnapshot: TxeAutomationMutationSnapshot;
  lRow, lListRow: TJsonObject;
  lDryRun, lSpecified, lEditState, lHasPlans: Boolean;
  lDenied, lPhase: string;
  i, j, n, lBudget, lIndex: Integer;
begin
  // The GUI warns that modern games are unsupported. An unattended command
  // rejects those games rather than silently accepting a modal warning.
  if not (wbGameMode in [gmTES4, gmFO3, gmFNV]) then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Merged patches support TES4, FO3 and FNV only');
  if wbTranslationMode then raise xeAutomationMutationNotAllowed('Merged patches require ordinary edit mode');
  lDryRun := xeAutomationReadBooleanArg(AArgs, 'dryRun', lSpecified);
  if not lSpecified then lDryRun := True;
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDenied) then
    Exit(xeAutomationErrorsBuildConsentRequired('patches.merge', 'patch-mutation', lDenied));
  if not AArgs.Contains('records') or (AArgs.Types['records'] <> jdtArray) or
     (AArgs.A['records'].Count < 1) or (AArgs.A['records'].Count > 32) then
    raise xeAutomationInvalidRequest('records must contain 1..32 root locators');
  lTarget := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'targetFile'));
  for i := 0 to lTarget.RecordCount - 1 do
    if lTarget.Records[i].Signature <> 'TES4' then
      raise xeAutomationStateConflict('Merge target must be empty; use a new loaded plugin');
  if not lDryRun then xeAutomationRequireWritableTargetFile(lTarget);
  lPlans := TObjectList<TxeMergePlan>.Create(True);
  lMasters := TStringList.Create;
  lSeen := TStringList.Create;
  try
    lModules := wbModulesByLoadOrder;
    for i := Low(lModules) to High(lModules) do begin
      lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
      if not Assigned(lFile) or lFile.Equals(lTarget) then Continue;
      if lFile.LoadOrder >= lTarget.LoadOrder then
        raise xeAutomationInvalidTarget('Merge target must load after all contributing loaded plugins');
      lMasters.Add(lFile.FileName);
    end;
    if lMasters.Count > 254 then raise xeAutomationNewError('patch_capacity', 'Merge target would exceed 254 masters');
    lBudget := 0;
    lHasPlans := False;
    for i := 0 to AArgs.A['records'].Count - 1 do begin
      if AArgs.A['records'].Types[i] <> jdtObject then raise xeAutomationInvalidRequest('Every record must be a locator object');
      lLocator := xeAutomationParseLocator(AArgs.A['records'].O[i], True, False);
      if lLocator.Path <> '' then raise xeAutomationInvalidRequest('Merge selections must be root records');
      lSelected := xeAutomationRequireMainRecord(lLocator).MasterOrSelf;
      if lSeen.IndexOf(lSelected.LoadOrderFormID.ToString(False)) >= 0 then
        raise xeAutomationInvalidRequest('Merge selections contain duplicate record identities');
      lSeen.Add(lSelected.LoadOrderFormID.ToString(False));
      lPlan := TxeMergePlan.Create;
      lPlans.Add(lPlan);
      lPlan.Master := lSelected;
      lPlan.Build(lBudget);
      lHasPlans := lHasPlans or (lPlan.Outcome = 'planned');
    end;
    // Every list/baseline/counter check finishes before adding masters or copying
    // any record. Faulty ordered lists are structured skips of the entire record.
    lSnapshot := xeAutomationCaptureMutationSnapshot;
    Result := TJsonObject.Create;
    try
      Result.B['dryRun'] := lDryRun;
      Result.B['complete'] := False;
      Result.S['targetFile'] := lTarget.FileName;
      Result.S['persistence'] := 'in-memory-until-session.save-and-terminal-session.flush';
      Result.I['inspectedEntries'] := lBudget;
      for i := 0 to lMasters.Count - 1 do Result.A['requiredMasters'].Add(lMasters[i]);
      for lPlan in lPlans do begin
        lRow := Result.A['records'].AddObject;
        lRow.S['formId'] := lPlan.Master.LoadOrderFormID.ToString(False);
        lRow.S['signature'] := lPlan.Master.Signature;
        lRow.S['winnerFile'] := lPlan.Winner._File.FileName;
        lRow.S['outcome'] := lPlan.Outcome;
        lRow.B['applyAttempted'] := False;
        for n := Low(lPlan.Lists) to High(lPlan.Lists) do
          if Assigned(lPlan.Lists[n]) then begin
            lListRow := lRow.A['lists'].AddObject;
            lListRow.S['name'] := lPlan.Names[n];
            lListRow.I['entries'] := lPlan.Lists[n].Count;
            lListRow.B['changed'] := lPlan.Changed[n];
          end;
      end;
      lPhase := 'masters';
      lIndex := -1;
      lEditState := wbAllowInternalEdit;
      try
        try
          if not lDryRun and lHasPlans then begin
            lTarget.AddMastersIfMissing(lMasters, True, True);
            // Match the native counter boundary; restore global state on every
            // exception so one failed patch cannot change later edit semantics.
            wbAllowInternalEdit := False;
            for i := 0 to lPlans.Count - 1 do begin
              lIndex := i;
              lPlan := lPlans[i];
              if lPlan.Outcome <> 'planned' then Continue;
              Result.A['records'].O[i].B['applyAttempted'] := True;
              lPhase := 'copy-winning-record';
              lRecord := wbCopyElementToFile(lPlan.Winner, lTarget, False, True, '', '', '', '', False) as IwbMainRecord;
              if not lRecord._File.Equals(lTarget) then raise xeAutomationInvalidTarget('Native merge copy has wrong ownership');
              Result.A['records'].O[i].O['locator'].S['file'] := lTarget.FileName;
              Result.A['records'].O[i].O['locator'].S['formId'] := lRecord.LoadOrderFormID.ToString(False);
              lPhase := 'rewrite-lists';
              for n := Low(lPlan.Lists) to High(lPlan.Lists) do
                if lPlan.Changed[n] then begin
                  lRecord.RemoveElement(lPlan.Names[n]);
                  for j := 0 to lPlan.Lists[n].Count - 1 do
                    wbCopyElementToRecord(IwbElement(Pointer(lPlan.Lists[n].Objects[j])), lRecord, True, True);
                  if Supports(lRecord.ElementByName[lPlan.Names[n]], IwbContainerElementRef, lEntries) then begin
                    if lEntries.ElementCount <> lPlan.Lists[n].Count then raise xeAutomationInvalidTarget('Native merged entry count differs from plan');
                  end else if lPlan.Lists[n].Count <> 0 then raise xeAutomationInvalidTarget('Native merged list is missing');
                  if (n <= High(lPlan.Counts)) and (lPlan.Counts[n] <> '') then begin
                    lRecord.Add(lPlan.Counts[n], True);
                    lCount := lRecord.ElementByPath[lPlan.Counts[n]];
                    if Assigned(lCount) then lCount.NativeValue := lPlan.Lists[n].Count;
                  end;
                end;
              lRecord.UpdateRefs;
              Result.A['records'].O[i].S['outcome'] := 'applied';
            end;
            lPhase := 'clean-masters';
            lTarget.CleanMasters;
          end;
          Result.B['complete'] := True;
        except
          on E: Exception do begin
            if E is ExeAutomationError then Result.O['failure'].S['code'] := ExeAutomationError(E).Code
            else Result.O['failure'].S['code'] := xeAutomationErrorInternalError;
            Result.O['failure'].S['message'] := E.Message;
            Result.O['failure'].S['phase'] := lPhase;
            Result.O['failure'].I['index'] := lIndex;
            Result.O['failure'].B['partialKnown'] := False;
            if (lIndex >= 0) and (lPhase <> 'clean-masters') then
              Result.A['records'].O[lIndex].S['outcome'] := 'failed';
          end;
        end;
      finally wbAllowInternalEdit := lEditState; end;
      if not lDryRun then xeAutomationInvalidateRecordQueries;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      if Result.Contains('failure') then Result.O['failure'].B['partial'] := Result.B['changed'];
      Result.B['requiresSave'] := not lDryRun and lTarget.Modified;
    except Result.Free; raise; end;
  finally
    lSeen.Free;
    lMasters.Free;
    lPlans.Free;
  end;
end;

end.
