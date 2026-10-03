{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsRecords;

interface

uses
  JsonDataObjects,
  wbInterface,
  xeAutomationConflictSnapshot,
  xeAutomationDataLookup,
  xeAutomationObjectModel;

procedure xeAutomationRegisterRecordsCommands;

implementation

uses
  Classes,
  SysUtils,
  wbImplementation,
  wbLoadOrder,
  xeAutomationErrors,
  xeAutomationMutationAudit,
  xeAutomationMutationPolicy,
  xeAutomationJobs,
  xeAutomationRecordQueries,
  xeAutomationRegistry;

const
  xeAutomationRecordsListLimit = 100;

type
  TxeAutomationCreateParentSpec = record
    HasParent: Boolean;
    FileName: string;
    FormId: Cardinal;
    HasSubGroup: Boolean;
    SubGroup: string;
    HasCoords: Boolean;
    CoordX: SmallInt;
    CoordY: SmallInt;
  end;

function xeAutomationCompareFileLoadOrder(AList: TStringList; AIndex1, AIndex2: Integer): Integer;
var
  lFile1: IwbFile;
  lFile2: IwbFile;
begin
  if AIndex1 = AIndex2 then
    Exit(0);

  lFile1 := IwbFile(Pointer(AList.Objects[AIndex1]));
  lFile2 := IwbFile(Pointer(AList.Objects[AIndex2]));
  if Assigned(lFile1) and Assigned(lFile2) then begin
    Result := lFile1.LoadOrder - lFile2.LoadOrder;
    if Result <> 0 then
      Exit;
  end else if Assigned(lFile1) then
    Exit(-1)
  else if Assigned(lFile2) then
    Exit(1);

  Result := AnsiCompareText(AList[AIndex1], AList[AIndex2]);
end;

function xeAutomationNewMasterReport: TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.A['added'];
  Result.A['alreadyPresent'];
  Result.A['skipped'];
end;

procedure xeAutomationCaptureFileMasters(const AFile: IwbFile; const AMasters: TStrings);
var
  i: Integer;
begin
  AMasters.Clear;
  for i := 0 to Pred(AFile.MasterCount[True]) do
    AMasters.Add(AFile.Masters[i, True].FileName);
end;

function xeAutomationMasterAlreadyPresent(const AMasters: TStrings; const AFileName: string): Boolean;
begin
  Result := AMasters.IndexOf(AFileName) >= 0;
end;

function xeAutomationCollectCopyRequiredMasters(const ASourceRecord: IwbMainRecord; const AAsNew,
  ADeepCopy: Boolean): TStringList;
var
  lMasters: TwbFilesSet;
  lFile: IwbFile;
  lChildGroup: IwbGroupRecord;
  lContainer: IwbContainer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  try
    lMasters := TwbFilesSet.Create;
    try
      // Required-master collection is delegated to xEdit's native walker so copy_into
      // follows the same dependency rules as GUI copy operations for override/new modes.
      ASourceRecord.ReportRequiredMasters(lMasters, AAsNew, True, True);
      // Deep-copying a record with a child group uses the GUI's child-group copy seam,
      // so master preflight must include child-only dependencies before copy/add checks.
      if ADeepCopy and Supports(ASourceRecord.ChildGroup, IwbGroupRecord, lChildGroup) then
        lChildGroup.ReportRequiredMasters(lMasters, AAsNew);
      // Native copy recursively recreates ancestor groups/owners too. Their
      // direct dependencies must be planned before AddMaster can mutate a file.
      lContainer := ASourceRecord.Container;
      while Assigned(lContainer) do begin
        lContainer.ReportRequiredMasters(lMasters, AAsNew, False);
        lContainer := lContainer.Container;
      end;
      for lFile in lMasters do
        Result.AddObject(lFile.FileName, Pointer(lFile));
    finally
      lMasters.Free;
    end;
    Result.Sorted := False;
    Result.CustomSort(xeAutomationCompareFileLoadOrder);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationApplyCopyRequiredMasters(const ATargetFile: IwbFile; const ARequested: TStrings;
  const AAddRequiredMasters: Boolean): TJsonObject;
var
  lBefore: TStringList;
  lAfter: TStringList;
  lToAdd: TStringList;
  lMasterFile: IwbFile;
  i: Integer;
begin
  Result := xeAutomationNewMasterReport;
  try
    lBefore := nil;
    lAfter := nil;
    lToAdd := nil;
    try
      lBefore := TStringList.Create;
      lAfter := TStringList.Create;
      lToAdd := TStringList.Create;
      lBefore.Sorted := True;
      lBefore.Duplicates := dupIgnore;
      lAfter.Sorted := True;
      lAfter.Duplicates := dupIgnore;
      lToAdd.Sorted := True;
      lToAdd.Duplicates := dupIgnore;

      xeAutomationCaptureFileMasters(ATargetFile, lBefore);

      for i := 0 to Pred(ARequested.Count) do begin
        lMasterFile := IwbFile(Pointer(ARequested.Objects[i]));
        if SameText(ARequested[i], ATargetFile.FileName) then begin
          Result.A['skipped'].Add(ARequested[i]);
          Continue;
        end;

        if xeAutomationMasterAlreadyPresent(lBefore, ARequested[i]) then begin
          Result.A['alreadyPresent'].Add(ARequested[i]);
          Continue;
        end;

        if not AAddRequiredMasters then
          lToAdd.AddObject(ARequested[i], ARequested.Objects[i])
        else begin
          if Assigned(lMasterFile) and (lMasterFile.LoadOrder >= ATargetFile.LoadOrder) then
            raise xeAutomationInvalidTarget(Format(
              'Automation required master "%s" can not be added to "%s" because it does not load before the target',
              [ARequested[i], ATargetFile.FileName]
            ));
          lToAdd.AddObject(ARequested[i], ARequested.Objects[i]);
        end;
      end;

      if (lToAdd.Count > 0) and not AAddRequiredMasters then
        raise xeAutomationMutationNotAllowed(
          'Automation copy requires missing masters and addRequiredMasters is false'
        );

      if lToAdd.Count > 0 then begin
        lToAdd.Sorted := False;
        lToAdd.CustomSort(xeAutomationCompareFileLoadOrder);
        try
          ATargetFile.AddMastersIfMissing(lToAdd, True, True);
        except
          on E: ExeAutomationError do
            raise;
          on E: Exception do
            raise xeAutomationInvalidTarget(Format(
              'Automation required masters could not be added to "%s": %s',
              [ATargetFile.FileName, E.Message]
            ));
        end;
      end;

      xeAutomationCaptureFileMasters(ATargetFile, lAfter);
      for i := 0 to Pred(lToAdd.Count) do
        if not xeAutomationMasterAlreadyPresent(lBefore, lToAdd[i]) and xeAutomationMasterAlreadyPresent(lAfter, lToAdd[i]) then
          Result.A['added'].Add(lToAdd[i])
        else if xeAutomationMasterAlreadyPresent(lAfter, lToAdd[i]) then
          Result.A['alreadyPresent'].Add(lToAdd[i])
        else
          Result.A['skipped'].Add(lToAdd[i]);
    finally
      lToAdd.Free;
      lAfter.Free;
      lBefore.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationReadBooleanArgDefault(const AArgs: TJsonObject; const AName: string;
  const ADefault: Boolean): Boolean;
var
  lHasValue: Boolean;
begin
  Result := xeAutomationReadBooleanArg(AArgs, AName, lHasValue);
  if not lHasValue then
    Result := ADefault;
end;

function xeAutomationReadIncludeParentsArg(const AArgs: TJsonObject): Boolean;
begin
  Result := xeAutomationReadBooleanArgDefault(AArgs, 'includeParents', False);
end;

function xeAutomationRequireCreatableRecordSignature(const AArgs: TJsonObject): string;
begin
  Result := UpperCase(xeAutomationRequireStringArg(AArgs, 'signature'));
end;

function xeAutomationInvalidCreateParentRequest(const AMessage, AInvalidField: string): ExeAutomationError;
var
  lDetails: TJsonObject;
begin
  lDetails := TJsonObject.Create;
  try
    if AInvalidField <> '' then
      lDetails.S['invalidField'] := AInvalidField;
    Result := xeAutomationNewError(xeAutomationErrorInvalidRequest, AMessage, lDetails);
  finally
    lDetails.Free;
  end;
end;

function xeAutomationUnsupportedCreateParentRequest(const AParentSignature, AMessage: string): ExeAutomationError;
var
  lDetails: TJsonObject;
begin
  lDetails := TJsonObject.Create;
  try
    lDetails.S['unsupportedParent'] := AParentSignature;
    Result := xeAutomationNewError(xeAutomationErrorInvalidRequest, AMessage, lDetails);
  finally
    lDetails.Free;
  end;
end;

function xeAutomationReadCreateParentSpec(const AArgs: TJsonObject; out AParentSpec: TxeAutomationCreateParentSpec): Boolean;
var
  lParent: TJsonObject;
  lCoords: TJsonArray;
  lFormID: string;
  lCoordValue: Int64;
  i: Integer;
begin
  AParentSpec.HasParent := False;
  AParentSpec.FileName := '';
  AParentSpec.FormId := 0;
  AParentSpec.HasSubGroup := False;
  AParentSpec.SubGroup := '';
  AParentSpec.HasCoords := False;
  AParentSpec.CoordX := 0;
  AParentSpec.CoordY := 0;

  Result := xeAutomationArgPresent(AArgs, 'parent');
  if not Result then
    Exit;

  if AArgs.Types['parent'] <> jdtObject then
    raise xeAutomationInvalidCreateParentRequest('Automation records.create parent must be an object', 'parent');

  lParent := AArgs.O['parent'];
  AParentSpec.HasParent := True;
  AParentSpec.FileName := xeAutomationRequireStringArg(lParent, 'file');
  lFormID := xeAutomationRequireStringArg(lParent, 'formId');
  try
    AParentSpec.FormId := xeAutomationParseFormIdHex(lFormID);
  except
    on E: ExeAutomationError do
      raise xeAutomationInvalidCreateParentRequest(E.Message, 'parent.formId');
  end;
  AParentSpec.HasSubGroup := xeAutomationArgPresent(lParent, 'subGroup');
  if AParentSpec.HasSubGroup then begin
    AParentSpec.SubGroup := xeAutomationReadStringArg(lParent, 'subGroup');
    if AParentSpec.SubGroup = '' then
      raise xeAutomationInvalidCreateParentRequest('Automation records.create parent.subGroup must be a non-empty string', 'parent.subGroup');
  end;
  AParentSpec.HasCoords := xeAutomationArgPresent(lParent, 'coords');
  if AParentSpec.HasCoords then begin
    if lParent.Types['coords'] <> jdtArray then
      raise xeAutomationInvalidCreateParentRequest('Automation records.create parent.coords must be a two-integer array', 'parent.coords');
    lCoords := lParent.A['coords'];
    if lCoords.Count <> 2 then
      raise xeAutomationInvalidCreateParentRequest('Automation records.create parent.coords must contain exactly two integers: [x,y]', 'parent.coords');
    for i := 0 to 1 do begin
      if not (lCoords.Types[i] in [jdtInt, jdtLong]) then
        raise xeAutomationInvalidCreateParentRequest('Automation records.create parent.coords values must be integers', 'parent.coords');
      lCoordValue := lCoords.L[i];
      if (lCoordValue < Low(SmallInt)) or (lCoordValue > High(SmallInt)) then
        raise xeAutomationInvalidCreateParentRequest('Automation records.create parent.coords values must be in signed int16 range', 'parent.coords');
      if i = 0 then
        AParentSpec.CoordX := SmallInt(lCoordValue)
      else
        AParentSpec.CoordY := SmallInt(lCoordValue);
    end;
  end;
end;

procedure xeAutomationValidateWrldCreateParentShape(
  const AParentSpec: TxeAutomationCreateParentSpec;
  const ACreateSignature: TwbSignature);
begin
  // WRLD authoring must choose a CELL-owned worldspace bucket explicitly; other
  // signatures belong under a concrete CELL parent via the Phase 15D route.
  if ACreateSignature <> 'CELL' then
    raise xeAutomationInvalidCreateParentRequest(
      'Automation records.create WRLD parent requires signature CELL; create child records under a CELL parent instead',
      'signature'
    );
  if AParentSpec.HasSubGroup and AParentSpec.HasCoords then
    raise xeAutomationInvalidCreateParentRequest(
      'Automation records.create WRLD parent accepts either parent.subGroup:"Persistent" or parent.coords, not both',
      'parent'
    );
  if not AParentSpec.HasSubGroup and not AParentSpec.HasCoords then
    raise xeAutomationInvalidCreateParentRequest(
      'Automation records.create WRLD parent requires parent.subGroup:"Persistent" or parent.coords:[x,y]',
      'parent'
    );
end;

procedure xeAutomationResolveWrldCreateParentTarget(
  const AParentSpec: TxeAutomationCreateParentSpec;
  const AParent: IwbMainRecord;
  out ATargetGroup: IwbGroupRecord;
  out AExistingRecord: IwbMainRecord;
  out ACreateName: string);
var
  lChildGroup: IwbGroupRecord;
  lGridCell: TwbGridCell;
begin
  ATargetGroup := nil;
  AExistingRecord := nil;
  ACreateName := '';

  xeAutomationValidateWrldCreateParentShape(AParentSpec, 'CELL');

  if AParentSpec.HasSubGroup then begin
    if not SameText(AParentSpec.SubGroup, 'Persistent') then
      raise xeAutomationInvalidCreateParentRequest(
        Format('Automation records.create parent.subGroup "%s" is not supported for WRLD; use "Persistent" or parent.coords:[x,y]', [AParentSpec.SubGroup]),
        'parent.subGroup'
      );

    lChildGroup := AParent.EnsureChildGroup;
    ATargetGroup := lChildGroup;
    AExistingRecord := xeAutomationFindPersistentWorldCell(lChildGroup);
    if not Assigned(AExistingRecord) then
      ACreateName := 'CELL[P]';
    Exit;
  end;

  // Native group Add accepts the same silent world-CELL parameter syntax as the
  // GUI path (CELL[x,y]); that keeps Block/Sub-Block creation inside xEdit core.
  lChildGroup := AParent.EnsureChildGroup;
  ATargetGroup := lChildGroup;
  lGridCell.x := AParentSpec.CoordX;
  lGridCell.y := AParentSpec.CoordY;
  AExistingRecord := AParent.ChildByGridCell[lGridCell];
  if not Assigned(AExistingRecord) then
    ACreateName := Format('CELL[%d,%d]', [AParentSpec.CoordX, AParentSpec.CoordY]);
end;

function xeAutomationDefaultCellChildGroupForSignature(const ACreateSignature: TwbSignature): Integer;
begin
  if (ACreateSignature = 'REFR') or
     (ACreateSignature = 'ACHR') or
     (ACreateSignature = 'PGRD') or
     (ACreateSignature = 'LAND') or
     (ACreateSignature = 'NAVM') then
    Result := 9
  else
    Result := 8;
end;

function xeAutomationCellChildGroupForSubGroup(const ASubGroup: string): Integer;
begin
  if SameText(ASubGroup, 'Persistent') then
    Exit(8);
  if SameText(ASubGroup, 'Temporary') then
    Exit(9);
  if SameText(ASubGroup, 'Visible when Distant') then
    Exit(10);

  raise xeAutomationInvalidCreateParentRequest(
    Format('Automation records.create parent.subGroup "%s" is not supported for CELL', [ASubGroup]),
    'parent.subGroup'
  );
end;

function xeAutomationResolveCreateParentTarget(
  const AParentSpec: TxeAutomationCreateParentSpec;
  const ACreateSignature: TwbSignature;
  const ATargetFile: IwbFile;
  out ATargetGroup: IwbGroupRecord;
  out AExistingRecord: IwbMainRecord;
  out ACreateName: string): Boolean;
var
  lLocator: TxeAutomationLocator;
  lParent: IwbMainRecord;
  lChildGroup: IwbGroupRecord;
  lTargetGroupType: Integer;
begin
  ATargetGroup := nil;
  AExistingRecord := nil;
  ACreateName := '';
  Result := AParentSpec.HasParent;
  if not Result then
    Exit;

  lLocator.FileName := AParentSpec.FileName;
  lLocator.FormID := IntToHex(AParentSpec.FormId, 8);
  lLocator.Path := '';
  lParent := xeAutomationRequireMainRecord(lLocator);
  if not Assigned(lParent._File) or not lParent._File.Equals(ATargetFile) then
    raise xeAutomationInvalidTarget('Create parent must be owned by targetFile; copy the parent override first');
  xeAutomationRequireWritableRootRecordTarget(lParent);


  // The parent object is the write-side substitute for synthetic ChildGroup paths:
  // validate the small owner set before native Add sees a malformed target GRUP.
  if lParent.Signature = 'WRLD' then begin
    xeAutomationValidateWrldCreateParentShape(AParentSpec, ACreateSignature);
    xeAutomationResolveWrldCreateParentTarget(AParentSpec, lParent, ATargetGroup, AExistingRecord, ACreateName);
    Exit;
  end;
  if (lParent.Signature <> 'CELL') and (lParent.Signature <> 'DIAL') and (lParent.Signature <> 'QUST') then
    raise xeAutomationInvalidCreateParentRequest('parent record does not own a ChildGroup', 'parent.formId');

  if lParent.Signature = 'CELL' then begin
    if AParentSpec.HasSubGroup then
      lTargetGroupType := xeAutomationCellChildGroupForSubGroup(AParentSpec.SubGroup)
    else
      lTargetGroupType := xeAutomationDefaultCellChildGroupForSignature(ACreateSignature);

    lChildGroup := lParent.EnsureChildGroup;
    ATargetGroup := lChildGroup.FindChildGroup(lTargetGroupType, lParent);
    if not Assigned(ATargetGroup) then begin
      if lTargetGroupType = xeAutomationDefaultCellChildGroupForSignature(ACreateSignature) then
        ATargetGroup := lChildGroup
      else
        raise xeAutomationInvalidTarget(Format('Automation CELL sub-group "%s" is not resolvable for parent %s', [AParentSpec.SubGroup, lParent.LoadOrderFormID.ToString(False)]));
    end;
    Exit;
  end;

  if AParentSpec.HasSubGroup then
    raise xeAutomationInvalidCreateParentRequest(
      Format('Automation records.create parent.subGroup is not supported for %s parents', [string(lParent.Signature)]),
      'parent.subGroup'
    );

  // DIAL and QUST are one-level ChildGroup owners. EnsureChildGroup mirrors native
  // editor behavior for empty parents so the following Add remains the only record
  // creation seam and xEdit still owns signature validity.
  ATargetGroup := lParent.EnsureChildGroup;
end;

procedure xeAutomationWriteRecordSummary(const ATarget: TJsonObject; const ARecord: IwbMainRecord);
begin
  ATarget.S['kind'] := 'record';
  ATarget.S['signature'] := ARecord.Signature;
  ATarget.S['formId'] := ARecord.LoadOrderFormID.ToString(False);
  ATarget.B['isMaster'] := ARecord.IsMaster;
  ATarget.B['isDeleted'] := ARecord.IsDeleted;
  ATarget.B['isWinningOverride'] := ARecord.IsWinningOverride;
  ATarget.I['overrideCount'] := ARecord.OverrideCount;

  if ARecord.CanHaveEditorID and (Trim(ARecord.EditorID) <> '') then
    ATarget.S['editorId'] := xeAutomationBoundedText(ARecord.EditorID);
  if ARecord.CanHaveFullName and (Trim(ARecord.FullName) <> '') then
    ATarget.S['fullName'] := xeAutomationBoundedText(ARecord.FullName);
  if Trim(ARecord.DisplayNameKey) <> '' then
    ATarget.S['displayNameKey'] := xeAutomationBoundedText(ARecord.DisplayNameKey);
end;

function xeAutomationNewRecordResponse(const ARecord: IwbMainRecord): TJsonObject;
begin
  Result := xeAutomationNewObjectResponse(
    ARecord._File.FileName,
    ARecord.LoadOrderFormID.ToString(False),
    ''
  );
  xeAutomationWriteRecordSummary(Result.O['object'], ARecord);
  // Record responses stay shallow and point traversal through elements.children so
  // callers do not accidentally trigger an unbounded recursive record dump.
  xeAutomationAddChildrenRelation(Result);
end;

function xeAutomationNewListedRecordSummary(const ARecord: IwbMainRecord): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.O['locator'].S['file'] := ARecord._File.FileName;
  Result.O['locator'].S['formId'] := ARecord.LoadOrderFormID.ToString(False);
  Result.O['locator'].S['path'] := '';
  // List results stay intentionally shallow so the first enumeration primitive is
  // reviewable and bounded by summaries plus locators, not implicit deep traversal.
  xeAutomationWriteRecordSummary(Result.O['object'], ARecord);
end;

function xeAutomationNewListedRecordSummaryWithParents(const ARecord: IwbMainRecord;
  const AIncludeParents: Boolean): TJsonObject;
begin
  Result := xeAutomationNewListedRecordSummary(ARecord);
  if AIncludeParents then
    xeAutomationAppendParentsRelation(Result, xeAutomationCollectAncestorChain(ARecord, 16));
end;

function xeAutomationNewRecordResponseWithParents(const ARecord: IwbMainRecord;
  const AIncludeParents: Boolean): TJsonObject;
begin
  Result := xeAutomationNewRecordResponse(ARecord);
  if AIncludeParents then
    xeAutomationAppendParentsRelation(Result, xeAutomationCollectAncestorChain(ARecord, 16));
end;

procedure xeAutomationAppendChildGroupConflictSubBlock(const AResult: TJsonObject;
  const ASnapshot: TxeAutomationConflictSnapshot);
var
  lChildGroup: TJsonObject;
  lSignatures: TJsonObject;
  lHits: TJsonArray;
  lHit: TJsonObject;
  i: Integer;
begin
  if not ASnapshot.ChildGroup.Present then
    Exit;

  lChildGroup := AResult.O['childGroup'];
  lChildGroup.I['count'] := ASnapshot.ChildGroup.Count;
  lChildGroup.B['hasConflict'] := ASnapshot.ChildGroup.HasConflict;
  lChildGroup.B['conflictingHitsTruncated'] := ASnapshot.ChildGroup.ConflictingHitsTruncated;

  lSignatures := lChildGroup.O['signatures'];
  for i := Low(ASnapshot.ChildGroup.Signatures) to High(ASnapshot.ChildGroup.Signatures) do begin
    lSignatures.O[ASnapshot.ChildGroup.Signatures[i].Signature].I['total'] := ASnapshot.ChildGroup.Signatures[i].Total;
    lSignatures.O[ASnapshot.ChildGroup.Signatures[i].Signature].I['conflicting'] := ASnapshot.ChildGroup.Signatures[i].Conflicting;
  end;

  lHits := lChildGroup.A['conflictingHits'];
  for i := Low(ASnapshot.ChildGroup.ConflictingHits) to High(ASnapshot.ChildGroup.ConflictingHits) do begin
    lHit := xeAutomationNewListedRecordSummary(ASnapshot.ChildGroup.ConflictingHits[i].RecordRef);
    xeAutomationWriteConflictBlock(
      lHit.O['conflict'],
      ASnapshot.ChildGroup.ConflictingHits[i].ConflictAll,
      ASnapshot.ChildGroup.ConflictingHits[i].ConflictThis,
      nil
    );
    lHits.Add(lHit);
  end;
end;

function xeAutomationNewRecordConflictStatusResponse(const ARecord: IwbMainRecord;
  const ASnapshot: TxeAutomationConflictSnapshot): TJsonObject;
var
  lRecordObject: TJsonObject;
  lChildren: TJsonArray;
  i: Integer;
begin
  Result := TJsonObject.Create;
  lRecordObject := Result.O['record'];
  lRecordObject.O['locator'].S['file'] := ARecord._File.FileName;
  lRecordObject.O['locator'].S['formId'] := ARecord.LoadOrderFormID.ToString(False);
  lRecordObject.O['locator'].S['path'] := '';
  xeAutomationWriteRecordSummary(lRecordObject.O['object'], ARecord);

  xeAutomationWriteConflictBlock(Result.O['conflict'], ASnapshot.ConflictAll, ASnapshot.ConflictThis, ASnapshot.Participants);

  Result.O['children'].I['count'] := Length(ASnapshot.Children);
  Result.O['children'].B['truncated'] := ASnapshot.ChildrenTruncated;
  lChildren := Result.O['children'].A['items'];
  for i := Low(ASnapshot.Children) to High(ASnapshot.Children) do
    xeAutomationWriteConflictChildStub(lChildren.AddObject, ARecord, ASnapshot.Children[i]);

  // ChildGroup conflict signal is an additive read-only block; records without a
  // populated ChildGroup omit it entirely so pre-15C clients keep their old shape.
  xeAutomationAppendChildGroupConflictSubBlock(Result, ASnapshot);
end;

function xeAutomationRequireRootRecord(const AArgs: TJsonObject): IwbMainRecord;
var
  lLocator: TxeAutomationLocator;
begin
  lLocator := xeAutomationParseLocator(AArgs, True, False);

  // These relationship commands stay root-record only. Allowing child paths here
  // would silently widen the contract beyond the approved surface.
  if lLocator.Path <> '' then
    raise xeAutomationInvalidRequest('Automation locator path is not supported for this records command');

  Result := xeAutomationRequireMainRecord(lLocator);
end;

function xeAutomationRequireRootMutationRecord(const AArgs: TJsonObject): IwbMainRecord;
var
  lLocator: TxeAutomationLocator;
begin
  lLocator := xeAutomationParseLocator(AArgs, True, True);

  // Root-level record mutations are intentionally separated from element-path edits:
  // deleting or flagging a child path would cross into native container semantics that
  // are handled by dedicated element commands and different removability rules.
  if Trim(lLocator.Path) <> '' then
    raise xeAutomationInvalidRequest('Automation records mutation path must address the record root');

  // Mutation locators must name a record owned by the addressed file, not a master
  // record merely reachable through that file's load-order dependencies.
  Result := xeAutomationRequireOwnedMainRecord(lLocator);
end;

function xeAutomationNewListedRecordHitsResponse(const ASearch: TxeAutomationBoundedMainRecordSearch): TJsonObject;
var
  lHits: TJsonArray;
  i: Integer;
begin
  Result := TJsonObject.Create;
  Result.B['truncated'] := ASearch.Truncated;
  lHits := Result.A['hits'];
  for i := Low(ASearch.Hits) to High(ASearch.Hits) do
    lHits.Add(xeAutomationNewListedRecordSummary(ASearch.Hits[i]));

  Result.I['count'] := lHits.Count;
end;

function xeAutomationRecordsFindByFormID(const AArgs: TJsonObject): TJsonObject;
var
  lSearch: TxeAutomationMainRecordSearch;
  lHits: TJsonArray;
  lFileName: string;
  lIncludeParents: Boolean;
  i: Integer;
begin
  lIncludeParents := xeAutomationReadIncludeParentsArg(AArgs);
  lFileName := xeAutomationReadStringArg(AArgs, 'file');
  lSearch := xeAutomationFindMainRecordsByLoadOrderFormID(
    xeAutomationRequireStringArg(AArgs, 'formId'),
    lFileName
  );

  Result := TJsonObject.Create;
  Result.B['truncated'] := lSearch.Truncated;
  lHits := Result.A['hits'];
  for i := Low(lSearch.Hits) to High(lSearch.Hits) do
    lHits.Add(xeAutomationNewListedRecordSummaryWithParents(lSearch.Hits[i], lIncludeParents));

  Result.I['count'] := lHits.Count;

  // Keep the identity lookup response shallow: callers get concrete hits plus the
  // two canonical endpoints for the same FormID, without any recursive expansion.
  if Assigned(lSearch.MasterOrSelf) then
    Result.O['masterOrSelf'] := xeAutomationNewListedRecordSummaryWithParents(lSearch.MasterOrSelf, lIncludeParents);
  if Assigned(lSearch.WinningOverride) then
    Result.O['winningOverride'] := xeAutomationNewListedRecordSummaryWithParents(lSearch.WinningOverride, lIncludeParents);
end;

function xeAutomationRecordsFindByEditorID(const AArgs: TJsonObject): TJsonObject;
var
  lSearch: TxeAutomationBoundedMainRecordSearch;
  lHits: TJsonArray;
  lIncludeParents: Boolean;
  i: Integer;
begin
  lIncludeParents := xeAutomationReadIncludeParentsArg(AArgs);
  // Keep request-shape validation at the boundary so malformed signature inputs
  // fail as structured invalid_request responses before any record traversal starts.
  lSearch := xeAutomationFindMainRecordsByEditorID(
    xeAutomationRequireStringArg(AArgs, 'editorId'),
    xeAutomationReadStringArg(AArgs, 'signature')
  );

  Result := TJsonObject.Create;
  Result.B['truncated'] := lSearch.Truncated;
  lHits := Result.A['hits'];
  for i := Low(lSearch.Hits) to High(lSearch.Hits) do
    lHits.Add(xeAutomationNewListedRecordSummaryWithParents(lSearch.Hits[i], lIncludeParents));

  Result.I['count'] := lHits.Count;
end;

function xeAutomationRecordsApplyFilter(const AArgs: TJsonObject): TJsonObject;
var
  lPage: TxeAutomationMainRecords;
  lHits: TJsonArray;
  i: Integer;
begin
  xeAutomationReadApplyFilterLimitArg(AArgs); // Preserve the strict 1..100 filter contract.
  Result := TJsonObject.Create;
  try
  lPage := xeAutomationRecordQueryPage('filter', AArgs, Result);
  lHits := Result.A['hits'];
  for i := Low(lPage) to High(lPage) do
    lHits.Add(xeAutomationNewListedRecordSummary(lPage[i]));

  Result.I['count'] := lHits.Count;
  Result.I['offset'] := xeAutomationReadOffsetArg(AArgs) + Result.I['emittedTotal'] - lHits.Count;
  // nextOffset is retained for complete full pages. Sparse budget pages may
  // contain zero hits, so they use only nextCursor to avoid offset retry loops.
  if Result.B['truncated'] and (lHits.Count > 0) then
    Result.I['nextOffset'] := Result.I['offset'] + lHits.Count;
  xeAutomationVerifyRecordQueryRevision(Result);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationRecordsGet(const AArgs: TJsonObject): TJsonObject;
var
  lRecord: IwbMainRecord;
begin
  lRecord := xeAutomationRequireMainRecord(xeAutomationParseLocator(AArgs, True, False));
  Result := xeAutomationNewRecordResponseWithParents(lRecord, xeAutomationReadIncludeParentsArg(AArgs));
end;

function xeAutomationRecordsBaseRecord(const AArgs: TJsonObject): TJsonObject;
var
  lRecord: IwbMainRecord;
  lBaseRecord: IwbMainRecord;
begin
  lRecord := xeAutomationRequireRootRecord(AArgs);

  Result := TJsonObject.Create;
  Result.O['record'] := xeAutomationNewListedRecordSummary(lRecord);

  if lRecord.CanHaveBaseRecord and Supports(lRecord.BaseRecord, IwbMainRecord, lBaseRecord) then
    Result.O['baseRecord'] := xeAutomationNewListedRecordSummary(lBaseRecord)
  else
    Result['baseRecord'] := nil;
end;

function xeAutomationRecordsReferences(const AArgs: TJsonObject): TJsonObject;
var
  lPage: TxeAutomationMainRecords;
  lHits: TJsonArray;
  i: Integer;
begin
  Result := TJsonObject.Create;
  try
  lPage := xeAutomationRecordQueryPage('references', AArgs, Result);
  lHits := Result.A['hits'];
  for i := Low(lPage) to High(lPage) do
    lHits.Add(xeAutomationNewListedRecordSummary(lPage[i]));
  Result.I['count'] := lHits.Count;
  xeAutomationVerifyRecordQueryRevision(Result);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationRecordsReferencedBy(const AArgs: TJsonObject): TJsonObject;
var
  lPage: TxeAutomationMainRecords;
  lHits: TJsonArray;
  i: Integer;
begin
  Result := TJsonObject.Create;
  try
  lPage := xeAutomationRecordQueryPage('referenced_by', AArgs, Result);
  lHits := Result.A['hits'];
  for i := Low(lPage) to High(lPage) do
    lHits.Add(xeAutomationNewListedRecordSummary(lPage[i]));
  Result.I['count'] := lHits.Count;
  xeAutomationVerifyRecordQueryRevision(Result);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationRecordsConflictStatus(const AArgs: TJsonObject): TJsonObject;
var
  lRecord: IwbMainRecord;
  lSnapshot: TxeAutomationConflictSnapshot;
begin
  lRecord := xeAutomationRequireRootRecord(AArgs);
  lSnapshot := xeAutomationSnapshotRecordConflict(lRecord, xeAutomationReadSearchLimit(AArgs));
  Result := xeAutomationNewRecordConflictStatusResponse(lRecord, lSnapshot);
end;

function xeAutomationRecordsList(const AArgs: TJsonObject): TJsonObject;
var
  lPage: TxeAutomationMainRecords;
  lRecordList: TJsonArray;
  i: Integer;
begin
  Result := TJsonObject.Create;
  try
  lPage := xeAutomationRecordQueryPage('list', AArgs, Result);
  lRecordList := Result.A['records'];
  for i := Low(lPage) to High(lPage) do
    lRecordList.Add(xeAutomationNewListedRecordSummary(lPage[i]));
  Result.I['count'] := lRecordList.Count;
  xeAutomationVerifyRecordQueryRevision(Result);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationRecordsCreate(const AArgs: TJsonObject): TJsonObject;
var
  lFile: IwbFile;
  lGroupElement: IwbElement;
  lNewElement: IwbElement;
  lGroup: IwbGroupRecord;
  lParentSpec: TxeAutomationCreateParentSpec;
  lParentTargetGroup: IwbGroupRecord;
  lExistingParentRecord: IwbMainRecord;
  lRecord: IwbMainRecord;
  lSignature: string;
  lCreateSignature: TwbSignature;
  lCreateName: string;
  lEditorID: string;
  lAlreadyExists: Boolean;
  lChanged: Boolean;
  lBeforeEditorID: string;
  lRecordDef: PwbMainRecordDef;
  lSnapshot: TxeAutomationMutationSnapshot;
  lSteps: TArray<string>;
  lDeniedReason: string;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then begin
    Result := xeAutomationErrorsBuildConsentRequired('records.create', 'records-mutation', lDeniedReason);
    Exit;
  end;

  lFile := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'targetFile'));
  lSignature := xeAutomationRequireCreatableRecordSignature(AArgs);
  lCreateSignature := StrToSignature(lSignature);
  lEditorID := xeAutomationReadStringArg(AArgs, 'editorId');
  xeAutomationReadCreateParentSpec(AArgs, lParentSpec);
  xeAutomationRequireWritableTargetFile(lFile);
  // Definition support is knowable without Add, including empty parent groups.
  if not wbFindRecordDef(lCreateSignature, lRecordDef) then
    raise xeAutomationInvalidTarget('Record signature has no native definition');
  if (lEditorID <> '') and not lRecordDef^.ContainsKnownSubRecord[ksrEditorID] then
    raise xeAutomationMutationNotAllowed('Record signature cannot have an EditorID');
  lSnapshot := xeAutomationCaptureMutationSnapshot;
  lSteps := nil;
  lRecord := nil;
  lBeforeEditorID := '';


  try
    lAlreadyExists := False;
    if xeAutomationResolveCreateParentTarget(lParentSpec, lCreateSignature, lFile, lParentTargetGroup, lExistingParentRecord, lCreateName) then begin
      if not Assigned(lParentTargetGroup) then
        raise xeAutomationInvalidTarget(Format('Automation parent target group could not be resolved for signature %s', [lSignature]));
      if not SameText(lParentTargetGroup._File.FileName, lFile.FileName) then
        raise xeAutomationInvalidTarget(Format(
          'Automation records.create parent target must be owned by targetFile "%s"; create or copy the parent override first',
          [lFile.FileName]
        ));

      // Parent-spec creation lands in an existing ChildGroup owner chosen by the
      // caller, but still delegates signature support to the same native Add seam.
      if Assigned(lExistingParentRecord) then begin
        lNewElement := lExistingParentRecord;
        lAlreadyExists := True;
      end else begin
        if lCreateName = '' then
          lCreateName := lSignature;
        lNewElement := lParentTargetGroup.Add(lCreateName, True);
      end;
    end else begin
      // Top-level groups are a native file-structure seam. Automation deliberately
      // avoids protocol-side signature allow-lists here and lets xEdit's Add path
      // decide which signatures the active game/file model can actually create.
      lGroupElement := lFile.Add(lSignature, True);
      if not Supports(lGroupElement, IwbGroupRecord, lGroup) then
        raise xeAutomationInvalidTarget(Format('Automation record group could not be created for signature %s', [lSignature]));

      lNewElement := lGroup.Add(lSignature, True);
    end;

    if not Supports(lNewElement, IwbMainRecord, lRecord) then
      raise xeAutomationInvalidTarget(Format('Automation record could not be created for signature %s', [lSignature]));

    lSteps := ['record-resolved'];
    if lRecord.CanHaveEditorID then
      lBeforeEditorID := lRecord.EditorID;
    if lEditorID <> '' then begin
      if not lRecord.CanHaveEditorID then
        raise xeAutomationMutationNotAllowed(Format('Automation record signature %s cannot have an EditorID', [lSignature]));
      if lRecord.EditorID <> lEditorID then
        lRecord.EditorID := lEditorID;
      lSteps := ['record-resolved', 'editor-id-set'];
    end;
  except
    on E: Exception do begin
      // Removing a fresh record is feasible; rewinding consumed IDs or all group
      // creation is not. Never remove an existing parent record during rollback.
      if Assigned(lRecord) and not lAlreadyExists and lRecord.IsRemovable then begin
        try
          lRecord.Remove;
          lSteps := ['record-resolved', 'rollback-record-removed'];
        except
          lSteps := ['record-resolved', 'rollback-record-failed'];
        end;
      end;
      raise xeAutomationMutationFailure(E, xeAutomationErrorInvalidTarget, 'records.create', lSnapshot, lSteps);
    end;
  end;

  Result := TJsonObject.Create;
  try
    lChanged := not lAlreadyExists or (lRecord.CanHaveEditorID and (lBeforeEditorID <> lRecord.EditorID));
    Result.B['changed'] := lChanged;
    xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
    Result.B['created'] := lRecord.IsMaster and not lAlreadyExists;
    Result.B['override'] := not lRecord.IsMaster;
    if lAlreadyExists then
      Result.B['alreadyExists'] := True;
    Result.B['dirty'] := lFile.Modified;
    Result.O['file'] := xeAutomationNewFileSummary(lFile);
    Result.O['locator'].S['file'] := lFile.FileName;
    Result.O['locator'].S['formId'] := lRecord.LoadOrderFormID.ToString(False);
    Result.O['locator'].S['path'] := '';
    xeAutomationWriteRecordSummary(Result.O['record'], lRecord);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationRecordsDelete(const AArgs: TJsonObject): TJsonObject;
var
  lRecord: IwbMainRecord;
  lChildGroup: IwbGroupRecord;
  lFile: IwbFile;
  lRemovedRecord: TJsonObject;
  lDeniedReason: string;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then begin
    Result := xeAutomationErrorsBuildConsentRequired('records.delete', 'records-mutation', lDeniedReason);
    Exit;
  end;

  lRemovedRecord := nil;
  lRecord := xeAutomationRequireRootMutationRecord(AArgs);
  xeAutomationRequireWritableRootRecordTarget(lRecord);

  lFile := lRecord._File;
  lChildGroup := lRecord.ChildGroup;
  lRemovedRecord := xeAutomationNewListedRecordSummary(lRecord);
  try
    // Physical removal uses xEdit's native structure mutation seam and remains only in
    // daemon memory until session.save; records.mark_deleted covers Deleted-flag edits.
    lRecord.Remove;
    // Mirror native UI physical delete ordering so child GRUP data is removed with
    // records that own one instead of leaving orphaned groups in the patch structure.
    if Assigned(lChildGroup) then
      lChildGroup.Remove;

    Result := TJsonObject.Create;
    try
      Result.B['changed'] := True;
      Result.B['dirty'] := lFile.Modified;
      Result.O['file'] := xeAutomationNewFileSummary(lFile);
      Result.O['removedRecord'] := lRemovedRecord;
      lRemovedRecord := nil;
    except
      Result.Free;
      raise;
    end;
  finally
    lRemovedRecord.Free;
  end;
end;

function xeAutomationRecordsMarkDeleted(const AArgs: TJsonObject): TJsonObject;
var
  lRecord: IwbMainRecord;
  lFile: IwbFile;
  lExpectedDeleted: Boolean;
  lHasExpectedDeleted: Boolean;
  lBeforeDeleted: Boolean;
  lChanged: Boolean;
  lDeniedReason: string;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then begin
    Result := xeAutomationErrorsBuildConsentRequired('records.mark_deleted', 'records-mutation', lDeniedReason);
    Exit;
  end;

  lRecord := xeAutomationRequireRootMutationRecord(AArgs);
  xeAutomationRequireWritableRootRecordTarget(lRecord);

  lExpectedDeleted := xeAutomationReadBooleanArg(AArgs, 'expectedDeleted', lHasExpectedDeleted);
  lBeforeDeleted := lRecord.IsDeleted;

  if lHasExpectedDeleted and (lExpectedDeleted <> lBeforeDeleted) then
    // Expected-state checks fail before touching the native Deleted flag so clients can
    // safely retry optimistic workflows without accidentally changing stale targets.
    raise xeAutomationStateConflict(Format(
      'Automation records.mark_deleted expectedDeleted mismatch for %s:%s',
      [lRecord._File.FileName, lRecord.LoadOrderFormID.ToString(False)]
    ));

  lFile := lRecord._File;
  lChanged := not lBeforeDeleted;
  if lChanged then
    // xEdit exposes record deletion as a flag mutation here, distinct from Remove;
    // automation deliberately offers no undelete path through this surface.
    lRecord.IsDeleted := True;

  Result := TJsonObject.Create;
  try
    Result.B['changed'] := lChanged;
    Result.B['dirty'] := lFile.Modified;
    Result.O['file'] := xeAutomationNewFileSummary(lFile);
    Result.O['locator'].S['file'] := lFile.FileName;
    Result.O['locator'].S['formId'] := lRecord.LoadOrderFormID.ToString(False);
    Result.O['locator'].S['path'] := '';
    Result.O['before'].B['isDeleted'] := lBeforeDeleted;
    Result.O['after'].B['isDeleted'] := lRecord.IsDeleted;
    xeAutomationWriteRecordSummary(Result.O['record'], lRecord);
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationCopyIntoNilCopyHint(const ACopySource: IwbElement; const ATargetFile: IwbFile): string;
begin
  Result := 'Automation records.copy_into could not identify the copied main record';

  // This mirrors the nil-return gates in TwbGroupRecord.AddIfMissingInternal.CopyMainRecord.
  // Keep this diagnosis in sync if the planned Phase 17 native gates change.
  if wbIsStarfield and Assigned(ACopySource) and ACopySource.ContainsReflection
     and (wbStarfieldReverseEngineeringIncomplete or ACopySource.ContainsUnsafeReflection) then
    Exit('Source contains Reflection and can not be copied');

  if Assigned(ACopySource) and ACopySource.ContainsUnmappedFormID then
    if Assigned(ATargetFile) and (ATargetFile.FileStates * [fsIsGameMaster, fsIsHardcoded] = []) then
      if (ATargetFile.MasterCount[True] < 1) or (ATargetFile.Masters[0, True].FileStates * [fsIsGameMaster] = []) then
        Exit('Source contains Unmapped FormID and can not be copied into a module which does not have the game master as its first master');
end;

function xeAutomationIdentifyCopiedMainRecord(const ACopiedElement: IwbElement; const ACopySource: IwbElement;
  const ASourceRecord: IwbMainRecord; const ATargetFile: IwbFile; const AAsNew: Boolean): IwbMainRecord;
var
  lCopiedGroup: IwbGroupRecord;
begin
  Result := nil;

  if not AAsNew then begin
    // Deep-copying a child group mirrors the GUI seam and may return a group rather
    // than the owning record, so override mode re-resolves the stable source FormID
    // strictly in the target file instead of accepting a master-chain fallback.
    Result := xeAutomationResolveOwnedMainRecordInFile(ATargetFile, ASourceRecord.LoadOrderFormID.ToString(False));
    if Assigned(Result) then
      Exit;
  end;

  if Supports(ACopiedElement, IwbMainRecord, Result) then
    Exit;

  if Supports(ACopiedElement, IwbGroupRecord, lCopiedGroup) then
    Supports(lCopiedGroup.ChildrenOf, IwbMainRecord, Result);

  if not Assigned(Result) then
    if Assigned(ACopiedElement) then
      raise xeAutomationMutationNotAllowed('Automation records.copy_into could not identify the copied main record')
    else
      raise xeAutomationMutationNotAllowed(xeAutomationCopyIntoNilCopyHint(ACopySource, ATargetFile));
end;

procedure xeAutomationPreflightCopyMasters(const ATargetFile: IwbFile;
  const ARequested: TStrings; const AAddMasters: Boolean);
var
  lMaster: IwbFile;
  i: Integer;
begin
  for i := 0 to ARequested.Count - 1 do begin
    lMaster := IwbFile(Pointer(ARequested.Objects[i]));
    if SameText(ARequested[i], ATargetFile.FileName) or ATargetFile.HasMaster(ARequested[i]) then
      Continue;
    if not AAddMasters then
      raise xeAutomationMutationNotAllowed('Copy requires missing masters and addRequiredMasters is false');
    if not Assigned(lMaster) or (lMaster.LoadOrder >= ATargetFile.LoadOrder) then
      raise xeAutomationInvalidTarget('Required masters must be loaded before the target');
    if wbStarfieldReverseEngineeringIncomplete and wbComplexFileFileID and
      ((ATargetFile.ModuleType <> mtFull) or (lMaster.ModuleType <> mtFull)) then
      raise xeAutomationMutationNotAllowed('Native Starfield master additions require full modules');
  end;
end;

function xeAutomationLeveledEntry(const AElement: IwbElement): IwbContainerElementRef;
var
  lOuter: IwbContainerElementRef;
begin
  if not Supports(AElement, IwbContainerElementRef, lOuter) then
    raise xeAutomationInvalidTarget('Native leveled-list entry is not a container');
  // TES4 stores LVLO directly; later definitions put LVLO and COED inside an
  // outer entry. Resolve the payload without discarding entry ownership data.
  if Assigned(lOuter.ElementByName['Count']) and Assigned(lOuter.ElementByName['Level']) then
    Exit(lOuter);
  if not Supports(lOuter.ElementBySignature[StrToSignature('LVLO')], IwbContainerElementRef, Result) then
    raise xeAutomationInvalidTarget('Native leveled-list entry has no LVLO payload');
  if not Assigned(Result.ElementByName['Count']) or not Assigned(Result.ElementByName['Level']) then
    raise xeAutomationInvalidTarget('Native LVLO payload lacks count/level');
end;

procedure xeAutomationAdjustSpawnRate(const ARecord: IwbMainRecord);
const
  Counts: array[0..8] of Integer = (1, 1, 2, 2, 2, 2, 2, 3, 3);
var
  lEntries, lPayload: IwbContainerElementRef;
  lOriginals: TArray<IwbElement>;
  lCopy: IwbElement;
  i, j: Integer;
begin
  lEntries := ARecord.ElementByName['Leveled List Entries'] as IwbContainerElementRef;
  SetLength(lOriginals, lEntries.ElementCount);
  for i := Low(lOriginals) to High(lOriginals) do
    lOriginals[i] := lEntries.Elements[i];
  // Keep originals untouched; append nine complete entries per original using
  // the GUI sequence. Snapshot interfaces because sorted insertion moves paths.
  for i := Low(lOriginals) to High(lOriginals) do
    for j := Low(Counts) to High(Counts) do begin
      lCopy := lEntries.Assign(Low(Integer), lOriginals[i], False);
      lPayload := xeAutomationLeveledEntry(lCopy);
      lPayload.ElementByName['Count'].NativeValue := Counts[j];
    end;
  if lEntries.ElementCount <> Length(lOriginals) * 10 then
    raise xeAutomationInvalidTarget('Native spawn-rate transformation produced an unexpected entry count');
end;

function xeAutomationRecordsCopyInto(const AArgs: TJsonObject): TJsonObject;
var
  lSourceLocator: TxeAutomationLocator;
  lTargetLocator: TxeAutomationLocator;
  lSourceRecord: IwbMainRecord;
  lTargetFile: IwbFile;
  lExistingTarget: IwbMainRecord;
  lCopySource: IwbElement;
  lCopiedElement: IwbElement;
  lCopiedRecord: IwbMainRecord;
  lWrappedRecord: IwbMainRecord;
  lEntries, lEntry: IwbContainerElementRef;
  lAsWrapper, lAsSpawnRate, lDryRun: Boolean;
  lEditorID: string;
  lRequiredMasters: TStringList;
  lMasterReport: TJsonObject;
  lMode: string;
  lAsNew: Boolean;
  lDeepCopy: Boolean;
  lNativeDeepCopy: Boolean;
  lOverwrite: Boolean;
  lAddRequiredMasters: Boolean;
  lOverwroteExisting: Boolean;
  lEditorIDPrefix: string;
  lEditorIDSuffix: string;
  lDeniedReason: string;
  lSnapshot: TxeAutomationMutationSnapshot;
  lSteps: TArray<string>;
  i: Integer;
  lFailure: ExeAutomationError;
begin
  lMasterReport := nil;
  lSourceLocator := xeAutomationParseNestedLocatorArg(AArgs, 'source', True, True);
  lTargetLocator := xeAutomationParseNestedLocatorArg(AArgs, 'target', False, True);

  // copy_into is intentionally record-root only. Reject child paths at the protocol
  // boundary before native copy routines can infer broader element semantics.
  if lSourceLocator.Path <> '' then
    raise xeAutomationInvalidRequest('Automation records.copy_into source path is not supported');
  if lTargetLocator.Path <> '' then
    raise xeAutomationInvalidRequest('Automation records.copy_into target path is not supported');

  lMode := LowerCase(xeAutomationRequireStringArg(AArgs, 'mode'));
  if lMode = 'override' then
    lAsNew := False
  else if lMode = 'new' then
    lAsNew := True
  else if (lMode = 'wrapper') or (lMode = 'spawn_rate') then
    lAsNew := False
  else
    raise xeAutomationInvalidRequest(Format('Automation records.copy_into mode "%s" is not supported', [lMode]));

  lAsWrapper := lMode = 'wrapper';
  lAsSpawnRate := lMode = 'spawn_rate';
  lDryRun := xeAutomationReadBooleanArgDefault(AArgs, 'dryRun', lAsWrapper or lAsSpawnRate);
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then
    Exit(xeAutomationErrorsBuildConsentRequired('records.copy_into', 'records-mutation', lDeniedReason));

  lDeepCopy := xeAutomationReadBooleanArgDefault(AArgs, 'deepCopy', False);
  lOverwrite := xeAutomationReadBooleanArgDefault(AArgs, 'overwrite', False);
  lAddRequiredMasters := xeAutomationReadBooleanArgDefault(AArgs, 'addRequiredMasters', True);
  if lAsNew and lOverwrite then
    raise xeAutomationInvalidRequest('Automation records.copy_into overwrite is only supported for override mode');

  lEditorIDPrefix := xeAutomationReadStringArg(AArgs, 'editorIdPrefix');
  lEditorIDSuffix := xeAutomationReadStringArg(AArgs, 'editorIdSuffix');

  lSourceRecord := xeAutomationRequireMainRecord(lSourceLocator);
  lTargetFile := xeAutomationRequirePluginFile(lTargetLocator.FileName);
  xeAutomationRequireWritableTargetFile(lTargetFile);
  if (lAsNew or lAsWrapper) and lTargetFile.IsUpdate then
    raise xeAutomationMutationNotAllowed('New records cannot be copied into update plugins');

  if not lSourceRecord.CanCopy then
    raise xeAutomationMutationNotAllowed('Automation records.copy_into source record cannot be copied');

  if lAsWrapper or lAsSpawnRate then begin
    // Mirror the native leveled-list menu predicates, then verify the active
    // game's concrete entry definition rather than assuming a shared layout.
    if wbIsMorrowind or wbIsFallout76 then
      raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
        'Leveled-list transformations are unavailable for this game');
    if wbTranslationMode or lDeepCopy or lOverwrite then
      raise xeAutomationInvalidRequest('Wrapper/spawn-rate modes require translation mode off, deepCopy:false and overwrite:false');
    if not ((lSourceRecord.Signature = 'LVLB') or (lSourceRecord.Signature = 'LVLC') or
      (lSourceRecord.Signature = 'LVLI') or (lSourceRecord.Signature = 'LVLN') or
      (lSourceRecord.Signature = 'LVLP') or (lSourceRecord.Signature = 'LVSC') or
      (lSourceRecord.Signature = 'LVSP')) then
      raise xeAutomationInvalidTarget('Wrapper/spawn-rate modes require a native leveled-list record');
    if not Supports(lSourceRecord.ElementByName['Leveled List Entries'], IwbContainerElementRef, lEntries) then
      raise xeAutomationInvalidTarget('Source has no native leveled-list entries');
    if (lEntries.ElementCount < 1) or (lEntries.ElementCount > 128) then
      raise xeAutomationInvalidTarget('Transformation requires 1..128 source entries');
    if lAsSpawnRate and Assigned(lSourceRecord.ElementBySignature[StrToSignature('LLCT')]) and
       (lEntries.ElementCount * 10 > 255) then
      raise xeAutomationInvalidTarget('Spawn-rate expansion would exceed the native 8-bit LLCT limit');
    for i := 0 to lEntries.ElementCount - 1 do
      xeAutomationLeveledEntry(lEntries.Elements[i]);
    if lAsWrapper then begin
      lEditorID := xeAutomationRequireStringArg(AArgs, 'editorId');
      if Length(lEditorID) > 255 then
        raise xeAutomationInvalidRequest('Wrapper editorId exceeds 255 characters');
      if SameText(lEditorID, lSourceRecord.EditorID) then
        raise xeAutomationInvalidRequest('Wrapper editorId must differ from source');
      if Assigned(lTargetFile.RecordByEditorID[lEditorID]) then
        raise xeAutomationStateConflict('Wrapper editorId already exists in target');
    end;
  end;

  lExistingTarget := nil;
  if not lAsNew then begin
    // The existence precheck is about target ownership. A master record reachable
    // through the target's masters is not an existing override in the target file.
    lExistingTarget := xeAutomationResolveOwnedMainRecordInFile(lTargetFile, lSourceRecord.LoadOrderFormID.ToString(False));
    if Assigned(lExistingTarget) then begin
      if not lOverwrite then
        raise xeAutomationStateConflict(Format(
          'Automation records.copy_into target already contains override %s in %s',
          [lSourceRecord.LoadOrderFormID.ToString(False), lTargetFile.FileName]
        ));
      xeAutomationRequireWritableRootRecordTarget(lExistingTarget);
    end;
  end;
  lOverwroteExisting := Assigned(lExistingTarget) and lOverwrite;

  // Public deepCopy chooses descendant scope, not native payload assignment.
  // Native aDeepCopy:false creates a shell or leaves an existing record alone.
  // Always clone the selected element below; only explicit deepCopy selects its
  // ChildGroup. Overwrite must not silently expand a shallow selection.
  lNativeDeepCopy := lDeepCopy;
  if wbAllowMakePartial and lSourceRecord.CanBePartial and
     not lSourceRecord.IsPartialForm and not Assigned(lExistingTarget) then
    raise xeAutomationMutationNotAllowed('Full record copy requires native partial-form creation disabled');

  lCopySource := lSourceRecord;
  if lNativeDeepCopy and Assigned(lSourceRecord.ChildGroup) then
    lCopySource := lSourceRecord.ChildGroup;
  if wbIsStarfield and lCopySource.ContainsReflection and
     (wbStarfieldReverseEngineeringIncomplete or lCopySource.ContainsUnsafeReflection) then
    raise xeAutomationMutationNotAllowed('Source contains Reflection and cannot be copied');
  if not lAddRequiredMasters and lCopySource.ContainsUnmappedFormID and
     ((lTargetFile.MasterCount[True] = 0) or
      (lTargetFile.Masters[0, True].FileStates * [fsIsGameMaster] = [])) then
    raise xeAutomationMutationNotAllowed('Unmapped FormIDs require the game master as the first target master');

  lRequiredMasters := xeAutomationCollectCopyRequiredMasters(lSourceRecord, lAsNew, lNativeDeepCopy);
  lSnapshot := xeAutomationCaptureMutationSnapshot;
  lSteps := nil;
  try
    if lDryRun then begin
      xeAutomationPreflightCopyMasters(lTargetFile, lRequiredMasters, lAddRequiredMasters);
      Result := TJsonObject.Create;
      Result.B['dryRun'] := True;
      Result.B['changed'] := False;
      Result.S['mode'] := lMode;
      Result.S['persistence'] := 'read-only-plan';
      Result.O['source'].S['file'] := lSourceRecord._File.FileName;
      Result.O['source'].S['formId'] := lSourceRecord.LoadOrderFormID.ToString(False);
      Result.O['target'].S['file'] := lTargetFile.FileName;
      if lAsWrapper then Result.S['wrappedEditorId'] := lEditorID;
      if lAsSpawnRate then Result.I['additionalEntries'] := lEntries.ElementCount * 9;
      Exit;
    end;
    try
      xeAutomationPreflightCopyMasters(lTargetFile, lRequiredMasters, lAddRequiredMasters);
      lMasterReport := xeAutomationApplyCopyRequiredMasters(lTargetFile, lRequiredMasters, lAddRequiredMasters);
      lSteps := ['masters-ready'];
      lWrappedRecord := nil;
      if lAsWrapper then begin
        // Native wrapper order matters: preserve the payload in a fresh record
        // before resetting its override into a single forwarding entry.
        lCopiedElement := wbCopyElementToFile(lSourceRecord, lTargetFile, True, True,
          '', '', '', '', False);
        lWrappedRecord := xeAutomationIdentifyCopiedMainRecord(lCopiedElement, lSourceRecord,
          lSourceRecord, lTargetFile, True);
        lWrappedRecord.EditorID := lEditorID;
        lWrappedRecord.UpdateRefs;
        lSteps := ['masters-ready', 'wrapped-record-copied'];
      end;
      lCopiedElement := wbCopyElementToFile(lCopySource, lTargetFile, lAsNew, True,
        '', '', lEditorIDPrefix, lEditorIDSuffix, lOverwrite);
      lCopiedRecord := xeAutomationIdentifyCopiedMainRecord(lCopiedElement, lCopySource, lSourceRecord, lTargetFile, lAsNew);
      lSteps := ['masters-ready', 'record-copied'];
      if lAsWrapper then begin
        lCopiedRecord.Assign(Low(Integer), nil, False);
        if not Assigned(lCopiedRecord.ElementByName['Leveled List Entries']) then
          lCopiedRecord.Add('Leveled List Entries', True);
        lEntries := lCopiedRecord.ElementByName['Leveled List Entries'] as IwbContainerElementRef;
        if lEntries.ElementCount <> 1 then
          raise xeAutomationInvalidTarget('Native wrapper reset did not produce one entry');
        lEntry := xeAutomationLeveledEntry(lEntries.Elements[0]);
        lEntry.Elements[2].EditValue := lWrappedRecord.EditValue;
        lEntry.ElementByName['Count'].NativeValue := 1;
        lEntry.ElementByName['Level'].NativeValue := 1;
        lCopiedRecord.EditorID := lSourceRecord.EditorID;
        lCopiedRecord.UpdateRefs;
        lSteps := ['masters-ready', 'wrapped-record-copied', 'forwarding-list-written'];
      end else if lAsSpawnRate then begin
        xeAutomationAdjustSpawnRate(lCopiedRecord);
        lCopiedRecord.UpdateRefs;
        lSteps := ['masters-ready', 'record-copied', 'spawn-rate-adjusted'];
      end;
    except
      on E: Exception do begin
        lFailure := xeAutomationMutationFailure(E, xeAutomationErrorInvalidTarget, 'records.copy_into', lSnapshot, lSteps);
        if Assigned(lWrappedRecord) then begin
          lFailure.Details.O['wrappedLocator'].S['file'] := lWrappedRecord._File.FileName;
          lFailure.Details.O['wrappedLocator'].S['formId'] := lWrappedRecord.LoadOrderFormID.ToString(False);
        end;
        if Assigned(lCopiedRecord) then begin
          lFailure.Details.O['copiedLocator'].S['file'] := lCopiedRecord._File.FileName;
          lFailure.Details.O['copiedLocator'].S['formId'] := lCopiedRecord.LoadOrderFormID.ToString(False);
        end;
        raise lFailure;
      end;
    end;

    Result := TJsonObject.Create;
    try
      xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      Result.B['dirty'] := lTargetFile.Modified;
      Result.S['mode'] := lMode;
      Result.B['dryRun'] := False;
      Result.S['persistence'] := 'in-memory-until-session.save';
      if Assigned(lWrappedRecord) then begin
        Result.O['wrappedLocator'].S['file'] := lWrappedRecord._File.FileName;
        Result.O['wrappedLocator'].S['formId'] := lWrappedRecord.LoadOrderFormID.ToString(False);
      end;
      Result.B['deepCopy'] := lDeepCopy;
      Result.B['overwrite'] := lOverwrite;
      Result.B['overwroteExisting'] := lOverwroteExisting;
      Result.O['source'].S['file'] := lSourceLocator.FileName;
      Result.O['source'].S['formId'] := lSourceLocator.FormID;
      Result.O['source'].S['path'] := lSourceLocator.Path;
      Result.O['target'].S['file'] := lTargetFile.FileName;
      Result.O['target'].S['path'] := lTargetLocator.Path;
      Result.O['locator'].S['file'] := lCopiedRecord._File.FileName;
      Result.O['locator'].S['formId'] := lCopiedRecord.LoadOrderFormID.ToString(False);
      Result.O['locator'].S['path'] := '';
      Result.O['masters'] := lMasterReport;
      lMasterReport := nil;
      xeAutomationWriteRecordSummary(Result.O['record'], lCopiedRecord);
    except
      Result.Free;
      raise;
    end;
  finally
    lRequiredMasters.Free;
    lMasterReport.Free;
  end;
end;

function xeAutomationIdlePrefix(const AValue: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(LowerCase(Trim(StringReplace(AValue, '/', '\', [rfReplaceAll]))));
  if (Result = '') or (Length(Result) > 512) or (Pos(':', Result) > 0) or (Result[1] = '\') or
     (Pos('..', Result) > 0) then
    raise xeAutomationInvalidRequest('Idle model prefixes must be nonempty relative resource directories');
end;

function xeAutomationRecordsCopyIdleTree(const AArgs: TJsonObject): TJsonObject;
const
  MaxIdles = 128;
var
  lSources, lCopies: TArray<IwbMainRecord>;
  lModels, lEditorIds: TArray<string>;
  lInput: TJsonArray;
  lLocator: TxeAutomationLocator;
  lTarget: IwbFile;
  lRequired, lOneRequired: TStringList;
  lMasterReport, lMapping: TJsonObject;
  lOldPrefix, lNewPrefix, lPrefix, lSuffix, lModel, lDirectory: string;
  lDeniedReason, lPhase: string;
  lDryRun, lAddMasters: Boolean;
  lElement: IwbElement;
  lSnapshot: TxeAutomationMutationSnapshot;
  i, j, k: Integer;
begin
  // The GUI groups idle winners by model directory, not by graph descendants.
  // Explicit locators replace the GUI directory picker and bound the selected set.
  if (wbGameMode > gmFNV) or wbIsMorrowind then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
      'Native idle-tree copy supports Oblivion/Fallout 3/New Vegas numeric IDLE schemas');
  if wbTranslationMode then
    raise xeAutomationMutationNotAllowed('Idle-tree copy is unavailable in translation mode');
  if not AArgs.Contains('sources') or (AArgs.Types['sources'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Idle-tree copy requires sources array of record locators');
  lInput := AArgs.A['sources'];
  if (lInput.Count < 1) or (lInput.Count > MaxIdles) then
    raise xeAutomationInvalidRequest('Idle-tree copy requires 1..128 source records');
  lDryRun := xeAutomationReadBooleanArgDefault(AArgs, 'dryRun', True);
  lAddMasters := xeAutomationReadBooleanArgDefault(AArgs, 'addRequiredMasters', True);
  if not lDryRun and not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then
    Exit(xeAutomationErrorsBuildConsentRequired('records.copy_idle_tree', 'records-mutation', lDeniedReason));
  lTarget := xeAutomationRequirePluginFile(xeAutomationRequireStringArg(AArgs, 'targetFile'));
  xeAutomationRequireWritableTargetFile(lTarget);
  if lTarget.IsUpdate then
    raise xeAutomationMutationNotAllowed('Idle copies cannot be created in update plugins');
  lOldPrefix := xeAutomationIdlePrefix(xeAutomationRequireStringArg(AArgs, 'oldModelPrefix'));
  lNewPrefix := xeAutomationIdlePrefix(xeAutomationRequireStringArg(AArgs, 'newModelPrefix'));
  if SameText(lOldPrefix, lNewPrefix) then
    raise xeAutomationInvalidRequest('Idle copy requires a changed model prefix');
  lPrefix := xeAutomationReadStringArg(AArgs, 'editorIdPrefix');
  lSuffix := xeAutomationReadStringArg(AArgs, 'editorIdSuffix');
  if (lPrefix = '') and (lSuffix = '') then
    raise xeAutomationInvalidRequest('Idle copy requires editorIdPrefix or editorIdSuffix');
  SetLength(lSources, lInput.Count);
  SetLength(lCopies, lInput.Count);
  SetLength(lModels, lInput.Count);
  SetLength(lEditorIds, lInput.Count);
  lRequired := TStringList.Create;
  lRequired.Sorted := True;
  lRequired.Duplicates := dupIgnore;
  lMasterReport := nil;
  try
    for i := 0 to lInput.Count - 1 do begin
      if lInput.Types[i] <> jdtObject then
        raise xeAutomationInvalidRequest('Idle sources must be locator objects');
      lLocator := xeAutomationParseLocator(lInput.O[i], True, False);
      if lLocator.Path <> '' then
        raise xeAutomationInvalidRequest('Idle sources must address record roots');
      lSources[i] := xeAutomationRequireMainRecord(lLocator).WinningOverride;
      if (lSources[i].Signature <> 'IDLE') or not lSources[i].CanCopy then
        raise xeAutomationInvalidTarget('Idle sources must resolve to copyable winning IDLE records');
      for j := 0 to i - 1 do
        if lSources[j].Equals(lSources[i]) then
          raise xeAutomationInvalidRequest('Idle selection contains duplicate winning records');
      lElement := lSources[i].ElementByPath['MODL\MODL'];
      if not Assigned(lElement) then
        raise xeAutomationInvalidTarget('Idle source has no native model path');
      lModel := LowerCase(Trim(StringReplace(lElement.EditValue, '/', '\', [rfReplaceAll])));
      if (Length(lModel) > 1024) or (ExtractFileExt(lModel) = '') then
        raise xeAutomationInvalidTarget('Idle source must have a bounded model filename');
      lDirectory := ExcludeTrailingPathDelimiter(ExtractFilePath(lModel));
      if not SameText(lDirectory, lOldPrefix) then
        raise xeAutomationInvalidTarget('Every selected idle must belong to oldModelPrefix directory');
      lModels[i] := lNewPrefix + Copy(lModel, Length(lOldPrefix) + 1, MaxInt);
      lEditorIds[i] := lPrefix + lSources[i].EditorID + lSuffix;
      if (Length(lEditorIds[i]) > 255) or Assigned(lTarget.RecordByEditorID[lEditorIds[i]]) then
        raise xeAutomationStateConflict('Copied idle EditorID is too long or already exists in target');
      for j := 0 to i - 1 do
        if SameText(lEditorIds[j], lEditorIds[i]) then
          raise xeAutomationStateConflict('Copied idle EditorIDs must be unique');
      lOneRequired := xeAutomationCollectCopyRequiredMasters(lSources[i], True, True);
      try
        for j := 0 to lOneRequired.Count - 1 do
          lRequired.AddObject(lOneRequired[j], lOneRequired.Objects[j]);
      finally
        lOneRequired.Free;
      end;
    end;
    xeAutomationPreflightCopyMasters(lTarget, lRequired, lAddMasters);
    lSnapshot := xeAutomationCaptureMutationSnapshot;
    Result := TJsonObject.Create;
    try
      Result.B['dryRun'] := lDryRun;
      Result.B['complete'] := False;
      Result.I['planned'] := lInput.Count;
      Result.I['copied'] := 0;
      Result.I['rewritten'] := 0;
      Result.S['persistence'] := 'in-memory-until-session.save';
      Result.A['mappings'].Clear;
      for i := 0 to lInput.Count - 1 do begin
        lMapping := Result.A['mappings'].AddObject;
        lMapping.O['source'].S['file'] := lSources[i]._File.FileName;
        lMapping.O['source'].S['formId'] := lSources[i].LoadOrderFormID.ToString(False);
        lMapping.O['target'].S['file'] := lTarget.FileName;
        lMapping.S['editorId'] := lEditorIds[i];
        lMapping.S['model'] := lModels[i];
        lMapping.B['copied'] := False;
        lMapping.B['rewritten'] := False;
      end;
      if not lDryRun then begin
        lPhase := 'masters';
        i := 0;
        try
          lMasterReport := xeAutomationApplyCopyRequiredMasters(lTarget, lRequired, lAddMasters);
          // Copy all records before replacing links. Allocating the complete map
          // first preserves hierarchy/condition links to later selection entries.
          lPhase := 'copy';
          for i := 0 to lInput.Count - 1 do begin
            lElement := wbCopyElementToFile(lSources[i], lTarget, True, True,
              '', '', lPrefix, lSuffix, False);
            lCopies[i] := xeAutomationIdentifyCopiedMainRecord(lElement, lSources[i], lSources[i], lTarget, True);
            lMapping := Result.A['mappings'].O[i];
            lMapping.O['target'].S['formId'] := lCopies[i].LoadOrderFormID.ToString(False);
            lMapping.B['copied'] := True;
            Result.I['copied'] := i + 1;
          end;
          lPhase := 'rewrite';
          for i := 0 to lInput.Count - 1 do begin
            lCopies[i].ElementEditValues['MODL\MODL'] := lModels[i];
            for k := 0 to lInput.Count - 1 do
              lCopies[i].CompareExchangeFormID(lSources[k].LoadOrderFormID, lCopies[k].LoadOrderFormID);
            lCopies[i].UpdateRefs;
            Result.A['mappings'].O[i].B['rewritten'] := True;
            Result.I['rewritten'] := i + 1;
          end;
        except
          on E: Exception do begin
            if E is ExeAutomationError then
              Result.O['failure'].S['code'] := ExeAutomationError(E).Code
            else
              Result.O['failure'].S['code'] := xeAutomationErrorInternalError;
            Result.O['failure'].S['message'] := E.Message;
            Result.O['failure'].S['phase'] := lPhase;
            Result.O['failure'].I['index'] := i;
            if (E is ExeAutomationError) and Assigned(ExeAutomationError(E).Details) then
              Result.O['failure'].O['details'].Assign(ExeAutomationError(E).Details);
          end;
        end;
        xeAutomationInvalidateRecordQueries;
        xeAutomationWriteMutationAudit(Result.O['mutationState'], lSnapshot);
        Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
        if Result.Contains('failure') then begin
          Result.O['failure'].B['partialKnown'] := Result.B['changed'];
          if Result.B['changed'] then Result.O['failure'].B['partial'] := True
          else Result.O['failure']['partial'] := nil;
        end;
        if Assigned(lMasterReport) then begin
          Result.O['masters'] := lMasterReport;
          lMasterReport := nil;
        end;
      end else
        Result.B['changed'] := False;
      Result.B['complete'] := not Result.Contains('failure');
      Result.A['dirtyFiles'].Clear;
      if not lDryRun and lTarget.Modified then
        Result.A['dirtyFiles'].Add(lTarget.FileName);
    except
      Result.Free;
      raise;
    end;
  finally
    lRequired.Free;
    lMasterReport.Free;
  end;
end;

procedure xeAutomationValidateInjectedCleanup(var ADryRun: Boolean;
  const ADryRunSpecified: Boolean; const ATarget, AOptions: TJsonObject);
var
  lFiles, lRecords, lPlan: TJsonArray;
  lFile, lInjectionFile, lCommonInjectionFile: IwbFile;
  lSource, lExisting: IwbMainRecord;
  lInjectionFiles: TwbFiles;
  lLocator: TxeAutomationLocator;
  lRequired: TStringList;
  lModules: TwbModuleInfos;
  lEntry: TJsonObject;
  lOverwrite, lAddMasters, lSelected: Boolean;
  i, j: Integer;
begin
  if wbIsMorrowind then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode,
      'Injected cleanup requires numeric FormIDs');
  if wbTranslationMode then
    raise xeAutomationMutationNotAllowed('Injected cleanup is unavailable in translation mode');
  if not ADryRunSpecified then ADryRun := True;
  if not Assigned(ATarget) or not ATarget.Contains('files') or
     (ATarget.Types['files'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Injected cleanup requires target.files array');
  lFiles := ATarget.A['files'];
  if (lFiles.Count < 1) or (lFiles.Count > 32) then
    raise xeAutomationInvalidRequest('Injected cleanup requires 1..32 source files');
  if not Assigned(AOptions) or not AOptions.Contains('records') or
     (AOptions.Types['records'] <> jdtArray) then
    raise xeAutomationInvalidRequest('Injected cleanup requires options.records locator array');
  lRecords := AOptions.A['records'];
  if (lRecords.Count < 1) or (lRecords.Count > 128) then
    raise xeAutomationInvalidRequest('Injected cleanup requires 1..128 explicit record locators');
  lOverwrite := xeAutomationReadBooleanArgDefault(AOptions, 'overwrite', False);
  lAddMasters := xeAutomationReadBooleanArgDefault(AOptions, 'addRequiredMasters', True);
  for i := 0 to lFiles.Count - 1 do begin
    if lFiles.Types[i] <> jdtString then
      raise xeAutomationInvalidRequest('target.files entries must be strings');
    lFile := xeAutomationRequirePluginFile(Trim(lFiles.S[i]));
    if not ADryRun then xeAutomationRequireWritableTargetFile(lFile);
    for j := 0 to i - 1 do
      if SameText(lFiles.S[j], lFiles.S[i]) then
        raise xeAutomationInvalidRequest('target.files contains duplicate files');
  end;
  // InjectionSourceFiles depends on the native reference cache. Construct it
  // before planning, without invoking RemoveInjected in a dry-run scene.
  lModules := wbModulesByLoadOrder;
  for i := Low(lModules) to High(lModules) do begin
    lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
    if Assigned(lFile) then lFile.BuildOrLoadRef(False);
  end;
  AOptions.Remove('_cleanupPlan');
  lPlan := AOptions.A['_cleanupPlan'];
  lCommonInjectionFile := nil;
  for i := 0 to lRecords.Count - 1 do begin
    if lRecords.Types[i] <> jdtObject then
      raise xeAutomationInvalidRequest('options.records entries must be locator objects');
    lLocator := xeAutomationParseLocator(lRecords.O[i], True, False);
    if lLocator.Path <> '' then
      raise xeAutomationInvalidRequest('Injected cleanup accepts record roots only');
    lSource := xeAutomationRequireOwnedMainRecord(lLocator);
    lSource.BuildRef;
    if (lSource.Signature = 'TES4') or not lSource.CanCopy then
      raise xeAutomationInvalidTarget('Injected cleanup requires copyable non-header records');
    lSelected := False;
    for j := 0 to lFiles.Count - 1 do
      if SameText(lSource._File.FileName, Trim(lFiles.S[j])) then lSelected := True;
    if not lSelected then
      raise xeAutomationInvalidRequest('Each selected record must belong to target.files');
    for j := 0 to i - 1 do
      if SameText(lPlan.O[j].S['file'], lSource._File.FileName) and
         SameText(lPlan.O[j].S['formId'], lSource.LoadOrderFormID.ToString(False)) then
        raise xeAutomationInvalidRequest('Injected cleanup contains duplicate records');
    lInjectionFiles := lSource.InjectionSourceFiles;
    if (Length(lInjectionFiles) <> 1) or not lSource.ReferencesInjected then
      raise xeAutomationInvalidTarget('Each selected record must reference injections from exactly one provider file');
    lInjectionFile := lInjectionFiles[0];
    if Assigned(lCommonInjectionFile) and not lCommonInjectionFile.Equals(lInjectionFile) then
      raise xeAutomationInvalidTarget('Selection must share one injection provider; split different providers into separate jobs');
    lCommonInjectionFile := lInjectionFile;
    if AOptions.Contains('injectionFile') and
       not SameText(xeAutomationRequireStringArg(AOptions, 'injectionFile'), lInjectionFile.FileName) then
      raise xeAutomationInvalidTarget('Injection provider differs from expected injectionFile');
    if not ADryRun then begin
      xeAutomationRequireWritableRootRecordTarget(lSource);
      xeAutomationRequireWritableTargetFile(lInjectionFile);
    end;
    lExisting := xeAutomationResolveOwnedMainRecordInFile(lInjectionFile, lSource.LoadOrderFormID.ToString(False));
    if Assigned(lExisting) then begin
      if not lOverwrite then
        raise xeAutomationStateConflict('Injection provider already owns an override; set overwrite:true explicitly');
      if not ADryRun then xeAutomationRequireWritableRootRecordTarget(lExisting);
    end;
    if wbIsStarfield and lSource.ContainsReflection and
      (wbStarfieldReverseEngineeringIncomplete or lSource.ContainsUnsafeReflection) then
      raise xeAutomationMutationNotAllowed('Reflection records cannot be preserved by copy');
    lRequired := xeAutomationCollectCopyRequiredMasters(lSource, False, True);
    try
      xeAutomationPreflightCopyMasters(lInjectionFile, lRequired, lAddMasters);
      lEntry := lPlan.AddObject;
      for j := 0 to lRequired.Count - 1 do
        if not SameText(lRequired[j], lInjectionFile.FileName) then begin
          lEntry.A['requiredMasters'].Add(lRequired[j]);
          if not lInjectionFile.HasMaster(lRequired[j]) then
            lEntry.A['missingMasters'].Add(lRequired[j]);
        end;
    finally
      lRequired.Free;
    end;
    lEntry.S['file'] := lSource._File.FileName;
    lEntry.S['formId'] := lSource.LoadOrderFormID.ToString(False);
    lEntry.S['signature'] := lSource.Signature;
    lEntry.S['injectionFile'] := lInjectionFile.FileName;
    lEntry.B['overwrite'] := Assigned(lExisting);
  end;
  if TEncoding.UTF8.GetByteCount(lPlan.ToJSON(False)) > 524288 then
    raise xeAutomationNewError('job_capacity', 'Injected cleanup dependency plan exceeds 512 KiB; split the selection');
end;

procedure xeAutomationCleanupDirtyFile(const AFiles: TJsonArray; const AFile: IwbFile);
var
  i: Integer;
begin
  if not AFile.Modified then Exit;
  for i := 0 to AFiles.Count - 1 do
    if SameText(AFiles.S[i], AFile.FileName) then Exit;
  AFiles.Add(AFile.FileName);
end;

procedure xeAutomationInjectedCleanupJob(const AJobId: string;
  const ADryRun, ADryRunSpecified: Boolean; const ATarget, AOptions: TJsonObject;
  const AFindings: TJsonArray; const ASummary, AResult, AFailure: TJsonObject);
var
  lPlan: TJsonArray;
  lLocator: TxeAutomationLocator;
  lSource, lPreserved: IwbMainRecord;
  lInjectionFile: IwbFile;
  lElement: IwbElement;
  lRequired: TStringList;
  lMasterReport, lFinding, lChanged: TJsonObject;
  lAddMasters, lRemaining: Boolean;
  lPhase: string;
  i, j: Integer;
  lGenerationBefore: UInt64;
begin
  lGenerationBefore := wbGlobalModifedGeneration;
  lPlan := AOptions.A['_cleanupPlan'];
  lAddMasters := xeAutomationReadBooleanArgDefault(AOptions, 'addRequiredMasters', True);
  ASummary.B['dryRun'] := ADryRun;
  ASummary.I['planned'] := 0;
  ASummary.I['applied'] := 0;
  ASummary.I['requiresManualReview'] := 0;
  ASummary.S['persistence'] := 'in-memory-until-session.save';
  AResult.A['records'].Clear;
  for i := 0 to lPlan.Count - 1 do begin
    if not SameText(lPlan.O[i].S['file'], Trim(ATarget.A['files'].S[0])) then Continue;
    ASummary.I['planned'] := ASummary.I['planned'] + 1;
    lFinding := AFindings.AddObject;
    lFinding.S['source'] := 'cleaning.cleanup_injected_references';
    lFinding.S['severity'] := 'info';
    lFinding.S['code'] := 'injected_cleanup_planned';
    lFinding.O['target'].S['file'] := lPlan.O[i].S['file'];
    lFinding.O['target'].S['formId'] := lPlan.O[i].S['formId'];
    lFinding.O['target'].S['signature'] := lPlan.O[i].S['signature'];
    lFinding.S['injectionFile'] := lPlan.O[i].S['injectionFile'];
    if lPlan.O[i].Contains('requiredMasters') then
      lFinding.A['requiredMasters'].Assign(lPlan.O[i].A['requiredMasters']);
    if lPlan.O[i].Contains('missingMasters') then
      lFinding.A['missingMasters'].Assign(lPlan.O[i].A['missingMasters']);
    lFinding.B['applied'] := False;
    if ADryRun then Continue;
    lPhase := 'resolve';
    try
      lLocator.FileName := lPlan.O[i].S['file'];
      lLocator.FormID := lPlan.O[i].S['formId'];
      lLocator.Path := '';
      lSource := xeAutomationRequireOwnedMainRecord(lLocator);
      lInjectionFile := xeAutomationRequirePluginFile(lPlan.O[i].S['injectionFile']);
      lRequired := xeAutomationCollectCopyRequiredMasters(lSource, False, True);
      try
        lPhase := 'masters';
        lMasterReport := xeAutomationApplyCopyRequiredMasters(lInjectionFile, lRequired, lAddMasters);
        lMasterReport.Free;
      finally
        lRequired.Free;
      end;
      // Preserve the full original record in its injection provider first.
      // Removing first would discard exactly the data the override must retain.
      lPhase := 'preserve-copy';
      lElement := wbCopyElementToFile(lSource, lInjectionFile, False, True,
        '', '', '', '', lPlan.O[i].B['overwrite']);
      lPreserved := xeAutomationIdentifyCopiedMainRecord(lElement, lSource, lSource, lInjectionFile, False);
      if not lPreserved._File.Equals(lInjectionFile) or
         (lPreserved.LoadOrderFormID <> lSource.LoadOrderFormID) then
        raise xeAutomationInvalidTarget('Cleanup preservation copy does not belong to the injection provider at the source ID');
      lChanged := AResult.A['records'].AddObject;
      lChanged.O['source'].Assign(lFinding.O['target']);
      lChanged.O['preserved'].S['file'] := lInjectionFile.FileName;
      lChanged.O['preserved'].S['formId'] := lPreserved.LoadOrderFormID.ToString(False);
      lChanged.B['cleaned'] := False;
      lPhase := 'remove-injected';
      lRemaining := lSource.RemoveInjected(False);
      lSource.UpdateRefs;
      lPreserved.UpdateRefs;
      // Native false means automatic removal completed; independently expose
      // current ReferencesInjected so required/unremovable fields stay visible.
      lRemaining := lRemaining or lSource.ReferencesInjected;
      lChanged.B['cleaned'] := not lRemaining;
      lChanged.B['requiresManualReview'] := lRemaining;
      lFinding.B['applied'] := True;
      lFinding.B['requiresManualReview'] := lRemaining;
      lFinding.S['code'] := 'injected_cleanup_applied';
      if lRemaining then begin
        lFinding.S['severity'] := 'warning';
        lFinding.S['code'] := 'injected_cleanup_incomplete';
        ASummary.I['requiresManualReview'] := ASummary.I['requiresManualReview'] + 1;
      end;
      ASummary.I['applied'] := ASummary.I['applied'] + 1;
    except
      on E: Exception do begin
        if E is ExeAutomationError then AFailure.S['code'] := ExeAutomationError(E).Code
        else AFailure.S['code'] := xeAutomationErrorInternalError;
        AFailure.S['message'] := E.Message;
        AFailure.S['phase'] := lPhase;
        AFailure.I['recordIndex'] := i;
        if (E is ExeAutomationError) and Assigned(ExeAutomationError(E).Details) then
          AFailure.O['details'].Assign(ExeAutomationError(E).Details);
        Break;
      end;
    end;
  end;
  ASummary.B['changed'] := wbGlobalModifedGeneration <> lGenerationBefore;
  ASummary.B['requiresSave'] := not ADryRun and ASummary.B['changed'];
  if not ADryRun then xeAutomationInvalidateRecordQueries;
  ASummary.A['dirtyFiles'].Clear;
  for j := 0 to lPlan.Count - 1 do begin
    lInjectionFile := xeAutomationRequirePluginFile(lPlan.O[j].S['injectionFile']);
    xeAutomationCleanupDirtyFile(ASummary.A['dirtyFiles'], lInjectionFile);
    lInjectionFile := xeAutomationRequirePluginFile(lPlan.O[j].S['file']);
    xeAutomationCleanupDirtyFile(ASummary.A['dirtyFiles'], lInjectionFile);
  end;
end;

function xeAutomationRecordsMasterOrSelf(const AArgs: TJsonObject): TJsonObject;
var
  lRecord: IwbMainRecord;
begin
  lRecord := xeAutomationRequireMainRecord(xeAutomationParseLocator(AArgs, True, False)).MasterOrSelf;
  Result := xeAutomationNewRecordResponseWithParents(lRecord, xeAutomationReadIncludeParentsArg(AArgs));
end;

function xeAutomationRecordsWinningOverride(const AArgs: TJsonObject): TJsonObject;
var
  lRecord: IwbMainRecord;
begin
  lRecord := xeAutomationRequireMainRecord(xeAutomationParseLocator(AArgs, True, False)).WinningOverride;
  Result := xeAutomationNewRecordResponseWithParents(lRecord, xeAutomationReadIncludeParentsArg(AArgs));
end;

procedure xeAutomationRegisterRecordsCommands;
begin
  // Cleanup shares native copy/dependency planning with records.copy_into;
  // register its job here so startup/capability probes use the same code seam.
  xeAutomationRegisterJobKindWithValidator('cleaning.cleanup_injected_references',
    xeAutomationInjectedCleanupJob, xeAutomationValidateInjectedCleanup);
  xeAutomationRegisterCommand('records.list', xeAutomationRecordsList);
  xeAutomationRegisterCommand('records.apply_filter', xeAutomationRecordsApplyFilter);
  xeAutomationRegisterCommand('records.base_record', xeAutomationRecordsBaseRecord);
  xeAutomationRegisterCommand('records.create', xeAutomationRecordsCreate);
  xeAutomationRegisterCommand('records.copy_into', xeAutomationRecordsCopyInto);
  xeAutomationRegisterCommand('records.copy_idle_tree', xeAutomationRecordsCopyIdleTree);
  xeAutomationRegisterCommand('records.delete', xeAutomationRecordsDelete);
  xeAutomationRegisterCommand('records.mark_deleted', xeAutomationRecordsMarkDeleted);
  xeAutomationRegisterCommand('records.conflict_status', xeAutomationRecordsConflictStatus);
  xeAutomationRegisterCommand('records.references', xeAutomationRecordsReferences);
  xeAutomationRegisterCommand('records.referenced_by', xeAutomationRecordsReferencedBy);
  xeAutomationRegisterCommand('records.find_by_form_id', xeAutomationRecordsFindByFormID);
  xeAutomationRegisterCommand('records.find_by_editor_id', xeAutomationRecordsFindByEditorID);
  xeAutomationRegisterCommand('records.get', xeAutomationRecordsGet);
  xeAutomationRegisterCommand('records.master_or_self', xeAutomationRecordsMasterOrSelf);
  xeAutomationRegisterCommand('records.winning_override', xeAutomationRecordsWinningOverride);
end;

end.
