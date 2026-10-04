{ This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. https://mozilla.org/MPL/2.0/ }
unit xeAutomationCommandsReplacement;
interface
implementation
uses SysUtils, Classes, TypInfo, JsonDataObjects, wbInterface, wbImplementation,
  xeAutomationRegistry, xeAutomationErrors, xeAutomationObjectModel,
  xeAutomationDataLookup, xeAutomationValues, xeAutomationMutationPolicy,
  xeAutomationMutationAudit, xeAutomationRecordQueries;

procedure WriteIdentity(const Json: TJsonObject; const R: IwbMainRecord);
begin
  Json.S['file'] := R._File.FileName;
  Json.S['formId'] := R.LoadOrderFormID.ToString(False);
end;

procedure WriteHeader(const Json: TJsonObject; const R: IwbMainRecord);
begin
  WriteIdentity(Json, R); Json.S['flags'] := IntToHex(R.Flags._Flags, 8);
  Json.S['vcs1'] := UIntToStr(R.VCS1);
  if wbGameMode >= gmFO3 then begin
    Json.S['version'] := UIntToStr(R.Version); Json.S['vcs2'] := UIntToStr(R.VCS2);
  end;
end;

function ReplacementOptions(const Args: TJsonObject): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.S['recordCommand'] := 'records.replace';
  Result.S['fieldCommand'] := 'batch.rows mode:replace';
  Result.S['fullValues'] := 'elements.get_value; elements.set_value/set_native_value; snapshots contain untrimmed leaf values';
  Result.S['inputs'] := 'source and target owned root locators, required expectedRevision; dryRun defaults true; addRequiredMasters defaults false';
  Result.S['scope'] := 'matching native definitions; full nondeleted nonlocalized records without child groups or CELL migration; matching file encodings; nonzero link leaves must resolve';
  Result.S['limits'] := '2048 payload nodes/depth16 and 256KiB JSON per snapshot; at most 32 missing dependencies';
  Result.S['headerPolicy'] := 'target FormID and placement preserved; source flags and FO3+ version copied; native VCS fields reset';
  Result.S['excluded'] := 'TES3/translation; TES4 header; reference/CELL/WRLD/DIAL roots; child groups; incomplete Starfield PKIN; same-chain no-copy fields; comparison-load sources/targets';
  Result.S['externalCompare'] := 'comparisons.load/records read-only; assigning from comparison-load files intentionally excluded until dependency/identity/persistence acceptance';
  Result.S['persistence'] := 'in-memory native Assign; explicit session.save and terminal session.flush; partial native failures do not roll back';
  Result.B['nativeAcceptancePending'] := True;
end;

procedure RequireRoot(const R: IwbMainRecord);
begin
  if (R.Signature = 'TES4') or R.IsDeleted or R.IsPartialForm then
    raise xeAutomationInvalidTarget('Replacement requires full nondeleted non-header roots');
  if (fsIsCompareLoad in R._File.FileStates) or R._File.IsLocalized then
    raise xeAutomationNewError('unsupported_replacement_scope', 'Comparison-load and localized records are excluded; use read-only comparisons and explicit field workflows');
  // Copying flags on a CELL child can migrate groups. Parent assignments can
  // strand child records. Keep both out of this identity-preserving payload seam.
  if not Assigned(R.Def) or R.Def.IsReference or Assigned(R.ChildGroup) or
    (R.Signature = 'CELL') or (R.Signature = 'WRLD') or (R.Signature = 'DIAL') or
    (R.Signature = 'REFR') or (R.Signature = 'PMIS') or (R.Signature = 'PGRE') or
    (R.Signature = 'ACRE') or (R.Signature = 'ACHR') or (R.Signature = 'PARW') or
    (R.Signature = 'PBEA') or (R.Signature = 'PFLA') or (R.Signature = 'PCON') or
    (R.Signature = 'PBAR') or (R.Signature = 'PHZD') then
    raise xeAutomationNewError('unsupported_replacement_scope', 'Child-group owners and CELL-migrating/reference roots require dedicated placement preflight');
  if wbStarfieldReverseEngineeringIncomplete and (R.Signature = 'PKIN') then
    raise xeAutomationNewError('unsupported_replacement_scope', 'Incomplete Starfield PKIN assignment is excluded');
end;

function PayloadSnapshot(const R: IwbMainRecord; const Json: TJsonObject): string;
var Canonical: TJsonObject; Visits, Bytes, i: Integer; E: IwbElement;
  procedure Visit(const E: IwbElement; const Ordinal: string; Depth: Integer);
  var C: IwbContainer; Link: IwbMainRecord; Row, Semantic: TJsonObject; i: Integer;
  begin
    Inc(Visits);
    if (Visits > 2048) or (Depth > 16) then
      raise xeAutomationNewError('replacement_capacity', 'Payload exceeds 2048 nodes or depth 16');
    Row := Json.A['nodes'].AddObject; Semantic := Canonical.A['nodes'].AddObject;
    Row.S['ordinal'] := Ordinal; Semantic.S['ordinal'] := Ordinal;
    Row.S['path'] := xeAutomationElementLocatorPath(E);
    Row.S['type'] := GetEnumName(TypeInfo(TwbElementType), Ord(E.ElementType));
    Semantic.S['type'] := Row.S['type'];
    if Assigned(E.Def) then begin
      Row.S['definition'] := E.Def.Name; Semantic.S['definition'] := E.Def.Name;
    end;
    if Supports(E, IwbContainer, C) and (C.ElementCount > 0) then begin
      Row.I['children'] := C.ElementCount; Semantic.I['children'] := C.ElementCount;
      if C.ElementCount > 2048 - Visits then
        raise xeAutomationNewError('replacement_capacity', 'Payload child count exceeds node budget');
      for i := 0 to C.ElementCount - 1 do Visit(C.Elements[i], Ordinal + '/' + IntToStr(i), Depth+1);
    end else if Assigned(E.ValueDef) then begin
      xeAutomationWriteFullValues(Row.O['values'], E);
      if not Row.O['values'].O['nativeValue'].B['available'] then
        raise xeAutomationNewError('unsupported_replacement_scope', 'Payload contains a native value without lossless readback');
      if Supports(E.LinksTo, IwbMainRecord, Link) then begin
        // Relative master slots differ between files. Compare resolved identity,
        // not the integer slot or source/target-specific formatted link labels.
        Link := Link.MasterOrSelf;
        WriteIdentity(Row.O['link'], Link); Semantic.O['link'].Assign(Row.O['link']);
      end else begin
        if E.CanContainFormIDs and ((Row.O['values'].O['nativeValue'].S['kind'] <> 'integer') or
          (Row.O['values'].O['nativeValue'].S['value'] <> '0')) then
          raise xeAutomationNewError('unsupported_replacement_scope', 'Nonzero or opaque FormID-bearing leaf has no resolved record identity; explicit field planning required');
        Semantic.S['editValue'] := Row.O['values'].S['editValue'];
        Semantic.O['nativeValue'].Assign(Row.O['values'].O['nativeValue']);
      end;
    end;
    Inc(Bytes, TEncoding.UTF8.GetByteCount(Row.ToJSON(False)) + 1);
    if Bytes > 260000 then raise xeAutomationNewError('replacement_capacity', 'Payload JSON exceeds the 256KiB snapshot budget');
  end;
begin
  Canonical := TJsonObject.Create; Visits := 0; Bytes := 0;
  try
    Json.A['nodes']; Canonical.A['nodes'];
    for i := 0 to R.ElementCount - 1 do begin
      E := R.Elements[i];
      // Negative sort-order elements are synthetic header/Contained In entries,
      // recreated by Assign rather than copied as serialized payload members.
      if E.SortOrder < 0 then Continue;
      Visit(E, IntToStr(E.SortOrder), 0);
    end;
    Json.I['nodeCount'] := Visits; Json.B['truncated'] := False;
    if TEncoding.UTF8.GetByteCount(Json.ToJSON(False)) > 262144 then
      raise xeAutomationNewError('replacement_capacity', 'Payload JSON exceeds the 256KiB snapshot budget');
    Result := Canonical.ToJSON(False);
  finally Canonical.Free; end;
end;

function ReplaceRecord(const Args: TJsonObject): TJsonObject;
var Source, Target: IwbMainRecord; TargetFile, Master: IwbFile;
  Locator: TxeAutomationLocator; TargetID: TwbFormID;
  Masters: TwbFilesSet; MasterArgs, MasterReport: TJsonObject;
  Snapshot: TxeAutomationMutationSnapshot; Failure: ExeAutomationError;
  Dry, AddMasters, Present: Boolean; Denied, Revision, Expected, Observed, Phase: string;
  i: Integer; SourceFlags, SourceVersion: Cardinal; PreviousProgress: TwbProgressCallback;
begin
  if wbIsMorrowind or wbTranslationMode then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Record replacement requires numeric plugin mode and translation mode off');
  Revision := xeAutomationRequireStringArg(Args, 'expectedRevision');
  if Revision <> UIntToStr(wbGlobalModifedGeneration) then
    raise xeAutomationNewError('stale_revision', 'Loaded mutation revision changed; reselect source/target');
  Dry := xeAutomationReadBooleanArg(Args, 'dryRun', Present); if not Present then Dry := True;
  AddMasters := xeAutomationReadBooleanArg(Args, 'addRequiredMasters', Present);
  if not Dry and not xeAutomationMutationPolicyConsentSatisfied(Denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('records.replace', 'plugin-mutation', Denied));
  Snapshot := xeAutomationCaptureMutationSnapshot;
  Result := TJsonObject.Create; MasterArgs := TJsonObject.Create; Masters := TwbFilesSet.Create;
  try
    try
      try
        Locator := xeAutomationParseNestedLocatorArg(Args, 'source', True, False);
        if Locator.Path <> '' then raise xeAutomationInvalidRequest('source must be a record root');
        Source := xeAutomationRequireOwnedMainRecord(Locator); RequireRoot(Source);
        Locator := xeAutomationParseNestedLocatorArg(Args, 'target', True, False);
        if Locator.Path <> '' then raise xeAutomationInvalidRequest('target must be a record root');
        Target := xeAutomationRequireOwnedMainRecord(Locator); RequireRoot(Target);
        if Target.Equals(Source) then raise xeAutomationInvalidRequest('source and target must be distinct records');
        if not Target.Def.Equals(Source.Def) then raise xeAutomationInvalidTarget('Source and target native record definitions must match');
        xeAutomationRequireWritableRootRecordTarget(Target);
        xeAutomationRequireCopyTargetAt(Target, Source, wbAssignThis);
        TargetFile := Target._File; TargetID := Target.LoadOrderFormID;
        if (Source._File.Encoding[False].CodePage <> TargetFile.Encoding[False].CodePage) or
           (Source._File.Encoding[True].CodePage <> TargetFile.Encoding[True].CodePage) then
          raise xeAutomationNewError('unsupported_replacement_scope', 'Whole-record assignment requires matching file encodings; use lossless field setters for conversion');
        if Source.MasterOrSelf.Equals(Target.MasterOrSelf) then
          for i := 0 to Source.ElementCount - 1 do
            if Assigned(Source.Elements[i].Def) and (dfNoCopyAsOverride in Source.Elements[i].Def.DefFlags) then
              raise xeAutomationNewError('unsupported_replacement_scope', 'Same-chain assignment would skip native no-copy fields; explicit field planning required');
        Result.B['dryRun'] := Dry; Result.S['outcome'] := 'planned';
        Result.S['persistence'] := 'in-memory replacement; explicit session.save and terminal session.flush';
        Result.S['headerPolicy'] := 'preserve target identity/placement; copy source flags/version; reset native VCS';
        WriteHeader(Result.O['source'], Source); WriteHeader(Result.O['before'], Target);
        SourceFlags := Source.Flags._Flags; SourceVersion := 0;
        if wbGameMode >= gmFO3 then SourceVersion := Source.Version;
        Expected := PayloadSnapshot(Source, Result.O['sourcePayload']);
        PayloadSnapshot(Target, Result.O['beforePayload']);
        // As-new collection plans payload links while excluding the source's
        // identity provider. This is replacement, not creation of its override.
        Source.ReportRequiredMasters(Masters, True, True, True);
        MasterArgs.S['targetFile'] := TargetFile.FileName; MasterArgs.B['dryRun'] := True;
        MasterArgs.A['masters']; Result.A['requiredMasters'];
        for Master in Masters do begin
          Result.A['requiredMasters'].Add(Master.FileName);
          if not Master.Equals(TargetFile) and not TargetFile.HasMaster(Master.FileName) then
            MasterArgs.A['masters'].Add(Master.FileName);
        end;
        if MasterArgs.A['masters'].Count > 0 then begin
          if not AddMasters then
            raise xeAutomationMutationNotAllowedWithDetails('Payload needs missing masters; review requiredMasters with addRequiredMasters:true and dryRun:true', Result);
          // Reuse explicit-master preflight, including capacity, extension,
          // load order and all-existing-master Starfield complex-slot gates.
          MasterReport := xeAutomationExecuteCommand('files.add_masters', MasterArgs);
          try Result.O['masterPlan'].Assign(MasterReport); finally MasterReport.Free; end;
        end;
        if Revision <> UIntToStr(wbGlobalModifedGeneration) then
          raise xeAutomationNewError('stale_revision', 'Loaded mutation revision changed during preflight');
      except
        on E: Exception do raise xeAutomationMutationFailure(E, xeAutomationErrorInvalidTarget, 'replacement-preflight', Snapshot, nil);
      end;
      if not Dry then begin
        Phase := 'add-required-masters'; PreviousProgress := _wbProgressCallback; _wbProgressCallback := nil;
        try
          try
            if MasterArgs.A['masters'].Count > 0 then begin
              MasterArgs.B['dryRun'] := False;
              MasterReport := xeAutomationExecuteCommand('files.add_masters', MasterArgs);
              try
                Result.O['masterApply'].Assign(MasterReport);
                if not MasterReport.B['complete'] then raise xeAutomationStateConflict('Native master addition was incomplete; record assignment not attempted');
              finally MasterReport.Free; end;
            end;
            Phase := 'native-assign'; xeAutomationRequireCopyTargetAt(Target, Source, wbAssignThis);
            // Assign(wbAssignThis) can return nil after replacing every child.
            // Its return value is never used as evidence of successful mutation.
            wbAutomationAssign(Target, wbAssignThis, Source);
            Result.B['assignCalled'] := True; Phase := 'refresh-and-readback'; Target.UpdateRefs;
            WriteHeader(Result.O['after'], Target);
            Observed := PayloadSnapshot(Target, Result.O['afterPayload']);
            Result.B['identityPreserved'] := Target.LoadOrderFormID = TargetID;
            Result.B['headerMatchesPolicy'] := (Target.Flags._Flags = SourceFlags) and (Target.VCS1 = DefaultVCS1);
            if wbGameMode >= gmFO3 then Result.B['headerMatchesPolicy'] := Result.B['headerMatchesPolicy'] and
              (Target.Version = SourceVersion) and (Target.VCS2 = DefaultVCS2);
            Result.B['payloadMatchesSource'] := Expected = Observed;
            if not Result.B['identityPreserved'] or not Result.B['headerMatchesPolicy'] or not Result.B['payloadMatchesSource'] then
              raise xeAutomationStateConflict('Native assignment readback differs from planned identity/header/payload; inspect snapshots before saving');
            Result.S['outcome'] := 'applied';
          except
            on E: Exception do begin
              Result.S['outcome'] := 'failed';
              Failure := xeAutomationMutationFailure(E, xeAutomationErrorInternalError, Phase, Snapshot, nil);
              try
                Result.O['failure'].S['code'] := Failure.Code; Result.O['failure'].S['message'] := Failure.Message;
                Result.O['failure'].O['details'].Assign(Failure.Details);
              finally Failure.Free; end;
              try Target.UpdateRefs;
              except on RefreshError: Exception do Result.O['failure'].S['referenceRefreshError'] := RefreshError.Message; end;
            end;
          end;
        finally _wbProgressCallback := PreviousProgress; end;
        // Assign invalidates payload interfaces even if a later readback fails.
        xeAutomationInvalidateRecordQueries; Result.B['pathsInvalidated'] := True;
      end;
      xeAutomationWriteMutationAudit(Result.O['mutationState'], Snapshot);
      Result.S['mutationRevision'] := UIntToStr(wbGlobalModifedGeneration);
      Result.B['changed'] := Result.O['mutationState'].B['mutationsObserved'];
      Result.B['requiresSave'] := not Dry and TargetFile.Modified;
      Result.B['complete'] := not Result.Contains('failure');
      Result.B['partial'] := not Result.B['complete'] and Result.B['changed'];
    except Result.Free; raise; end;
  finally Masters.Free; MasterArgs.Free; end;
end;

initialization
  // Registration at unit initialization matches the other self-contained
  // command units; xEdit.dpr explicitly links this unit into the daemon.
  xeAutomationRegisterCommand('records.replace', ReplaceRecord);
  xeAutomationRegisterCommand('records.replacement_options', ReplacementOptions);
end.
