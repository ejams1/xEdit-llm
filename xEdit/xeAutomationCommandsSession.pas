{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationCommandsSession;

interface

procedure xeAutomationRegisterSessionCommands;

implementation

uses
  xeAutomationRecordQueries,
  xeAutomationLocalizationState,
  SysUtils,
  Math,
  JsonDataObjects,
  wbInterface,
  wbLoadOrder,
  xeAutomationDataLookup,
  xeAutomationErrors,
  xeAutomationGuiSnapshot,
  xeAutomationMutationAudit,
  xeAutomationMutationPolicy,
  xeAutomationObjectModel,
  xeAutomationRegistry,
  xeAutomationServeLoop,
  xeMainForm;

function xeAutomationNewPendingFileSummary(const AFileName: string): TJsonObject;
var
  lFile: IwbFile;
begin
  lFile := xeAutomationTryPluginFile(AFileName);
  if Assigned(lFile) then
    Exit(xeAutomationNewFileSummary(lFile));

  // A pending queue entry is persistence state in its own right. If xEdit's
  // module-name index cannot resolve its FileNameOnDisk key (notably .ghost
  // names), preserve the non-raising readback with the identity still known.
  Result := TJsonObject.Create;
  Result.S['name'] := AFileName;
  Result.S['fileName'] := AFileName;
end;

function xeAutomationBuildDirtyState: TJsonObject;
var
  lModules: TwbModuleInfos;
  lDirtyFiles: TJsonArray;
  lPendingShutdownFiles: TJsonArray;
  lPendingShutdownSnapshot: TxePendingShutdownFiles;
  lPendingEntry: TJsonObject;
  lFile: IwbFile;
  i: Integer;
begin
  Result := TJsonObject.Create;
  lDirtyFiles := Result.A['dirtyFiles'];
  lPendingShutdownFiles := Result.A['pendingShutdownFiles'];

  // Dirty state belongs to the loaded daemon session, not to any single request:
  // each call asks about the same in-memory plugin set until the daemon exits.
  lModules := wbModulesByLoadOrder;
  for i := Low(lModules) to High(lModules) do begin
    lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
    if Assigned(lFile) and lFile.Modified then
      lDirtyFiles.Add(xeAutomationNewFileSummary(lFile));
  end;

  Result.S['mutationRevision'] := UIntToStr(wbGlobalModifedGeneration);
  Result.I['unsavedChangeCount'] := lDirtyFiles.Count;
  xeAutomationWriteLocalizationDirtyState(Result);
  Result.B['dirty'] := (lDirtyFiles.Count > 0) or (Result.I['dirtyLocalizationTableCount'] > 0);
  Result.I['unsavedChangeCount'] := lDirtyFiles.Count + Result.I['dirtyLocalizationTableCount'];

  xePendingShutdownSnapshot(lPendingShutdownSnapshot);
  for i := Low(lPendingShutdownSnapshot) to High(lPendingShutdownSnapshot) do begin
    lPendingEntry := lPendingShutdownFiles.AddObject;
    lPendingEntry.S['tempFile'] := lPendingShutdownSnapshot[i].TempName;
    lPendingEntry.O['file'] := xeAutomationNewPendingFileSummary(
      lPendingShutdownSnapshot[i].FileName
    );
  end;
  Result.I['pendingShutdownCount'] := lPendingShutdownFiles.Count;
  // Saving clears Modified before a memory-mapped module can be renamed. Thus a
  // pending entry intentionally coexists with dirty=false until shutdown/flush.
end;

function xeAutomationSessionGetDirtyState(const AArgs: TJsonObject): TJsonObject;
begin
  Result := xeAutomationBuildDirtyState;
end;

function xeAutomationSessionGetGuiSnapshot(const AArgs: TJsonObject): TJsonObject;
begin
  // GUI snapshot state belongs to the loaded daemon session because the caller is
  // asking about the current xEdit window environment, not request-local data.
  Result := xeAutomationBuildGuiSnapshot;
end;

function xeAutomationSessionSave(const AArgs: TJsonObject): TJsonObject;
var
  lSaveTargets: TxeAutomationTargetFiles;
  lSavedFilesNow, lSavedFilesPendingShutdown: TJsonArray;
  lSaveError, lDeniedReason, lCode: string;
  lWasDirty: Boolean;
  lDetails, lEntry: TJsonObject;
  i, j: Integer;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then
    Exit(xeAutomationErrorsBuildConsentRequired('session.save', 'session-mutation', lDeniedReason));
  // Resolve and validate every target before the first native save. A batch is
  // not atomic: preserve completed/failed/not-attempted state on any later error.
  lSaveTargets := xeAutomationResolveSaveTargets(AArgs);
  Result := TJsonObject.Create;
  try
    lSavedFilesNow := Result.A['savedFilesNow'];
    lSavedFilesPendingShutdown := Result.A['savedFilesPendingShutdown'];
    Result.A['steps'].Clear;
    for i := Low(lSaveTargets) to High(lSaveTargets) do begin
      lEntry := Result.A['steps'].AddObject;
      lEntry.S['fileName'] := lSaveTargets[i].FileName;
      lEntry.S['status'] := 'attempting';
      try
        lWasDirty := lSaveTargets[i].Modified;
        lSaveError := '';
        xeSavePluginFile(lSaveTargets[i], True, lSaveError);
        if (lSaveError <> '') and not xeSavePluginFilePendingShutdown(lSaveTargets[i]) then
          raise xeAutomationSaveFailed(Format('Automation save failed for %s: %s', [lSaveTargets[i].FileName, lSaveError]));
        if lWasDirty and lSaveTargets[i].Modified then
          raise xeAutomationSaveFailed('Native save left the requested file dirty');
        if lWasDirty then begin
          if xeSavePluginFilePendingShutdown(lSaveTargets[i]) then begin
            lSavedFilesPendingShutdown.Add(xeAutomationNewFileSummary(lSaveTargets[i]));
            lEntry.S['status'] := 'saved-pending-flush';
          end else begin
            lSavedFilesNow.Add(xeAutomationNewFileSummary(lSaveTargets[i]));
            lEntry.S['status'] := 'saved-now';
          end;
        end else
          lEntry.S['status'] := 'unchanged';
      except
        on E: Exception do begin
          lEntry.S['status'] := 'failed';
          lEntry.S['error'] := E.Message;
          lEntry.B['dirty'] := lSaveTargets[i].Modified;
          lEntry.B['pendingFlush'] := xeSavePluginFilePendingShutdown(lSaveTargets[i]);
          for j := i + 1 to High(lSaveTargets) do begin
            lEntry := Result.A['steps'].AddObject;
            lEntry.S['fileName'] := lSaveTargets[j].FileName;
            lEntry.S['status'] := 'not-attempted';
            lEntry.B['dirty'] := lSaveTargets[j].Modified;
          end;
          lDetails := TJsonObject.Create;
          try
            lCode := xeAutomationErrorSaveFailed;
            if E is ExeAutomationError then begin
              lCode := ExeAutomationError(E).Code;
              if Assigned(ExeAutomationError(E).Details) then
                lDetails.Assign(ExeAutomationError(E).Details);
            end;
            lDetails.S['phase'] := 'session.save';
            lDetails.O['outcome'].Assign(Result);
            lDetails.O['remainingState'] := xeAutomationBuildDirtyState;
            // The failing native save itself may have written output before
            // throwing. If no earlier save completed, its outcome is uncertain.
            if (lSavedFilesNow.Count + lSavedFilesPendingShutdown.Count > 0) then begin
              lDetails.B['partial'] := True;
              lDetails.B['partialKnown'] := True;
            end else begin
              lDetails['partial'] := nil;
              lDetails.B['partialKnown'] := False;
            end;
            lDetails.B['rollbackComplete'] := False;
            raise xeAutomationNewError(lCode, E.Message, lDetails);
          finally
            lDetails.Free;
          end;
        end;
      end;
    end;
    Result.I['savedNowCount'] := lSavedFilesNow.Count;
    Result.I['savePendingShutdownCount'] := lSavedFilesPendingShutdown.Count;
    Result.O['dirtyState'] := xeAutomationBuildDirtyState;
  except
    Result.Free;
    raise;
  end;
end;

function xeAutomationSessionFlush(const AArgs: TJsonObject): TJsonObject;
var
  lPendingBefore: TxePendingShutdownFiles;
  lDrainResults: TxePendingRenameResults;
  lPendingAfter: TxePendingShutdownFiles;
  lDirtyState: TJsonObject;
  lFlushedFiles: TJsonArray;
  lPendingRemaining: TJsonArray;
  lEntry: TJsonObject;
  lDeniedReason: string;
  lForceSpecified: Boolean;
  lForce: Boolean;
  i: Integer;
begin
  if not xeAutomationMutationPolicyConsentSatisfied(lDeniedReason) then begin
    Result := xeAutomationErrorsBuildConsentRequired('session.flush', 'session-mutation', lDeniedReason);
    Exit;
  end;

  lForce := xeAutomationReadBooleanArg(AArgs, 'force', lForceSpecified);
  if not lForceSpecified then
    lForce := False;
  xePendingShutdownSnapshot(lPendingBefore);
  // Force-closing the loaded file graph destroys the session, so preserve its
  // final dirty-state readback before the shared drain releases memory maps.
  lDirtyState := xeAutomationBuildDirtyState;
  try
    // Unsaved Modified files are not represented by the pending-rename queue.
    // Refuse to destroy them unless the caller explicitly accepts that loss.
    if lDirtyState.B['dirty'] and not lForce then
      raise xeAutomationStateConflict(
        'session.flush refuses unsaved plugins/string tables; call session.save and localization.save first or pass force:true'
      );

    try
      // Cursor stacks retain native interfaces; release them before graph close.
      xeAutomationInvalidateRecordQueries;
      xeDrainPendingRenames(lDrainResults);
    finally
      // From this point the file graph may already be invalid. Arm exit before
      // JSON construction so any later exception still terminates the daemon.
      xeAutomationServeLoopRequestExit;
    end;
    if Length(lDrainResults) <> Length(lPendingBefore) then
      raise xeAutomationNewError(
        xeAutomationErrorInternalError,
        'session.flush pending queue changed between snapshot and drain'
      );
    xePendingShutdownSnapshot(lPendingAfter);

    Result := TJsonObject.Create;
    lFlushedFiles := Result.A['flushedFiles'];
    for i := Low(lDrainResults) to High(lDrainResults) do begin
      lEntry := lFlushedFiles.AddObject;
      lEntry.S['fileName'] := lDrainResults[i].FileName;
      lEntry.B['renamed'] := lDrainResults[i].Renamed;
      if lDrainResults[i].Error <> '' then
        lEntry.S['error'] := lDrainResults[i].Error;
    end;

    lPendingRemaining := Result.A['pendingRemaining'];
    for i := Low(lPendingAfter) to High(lPendingAfter) do
      lPendingRemaining.Add(lPendingAfter[i].FileName);
    Result.I['pendingRemainingCount'] := lPendingRemaining.Count;
    Result.O['dirtyState'] := lDirtyState;
    lDirtyState := nil;
  finally
    lDirtyState.Free;
  end;
end;

function xeAutomationSessionOptions(const Args: TJsonObject): TJsonObject;
  procedure Exclude(const Name, Reason, Route: string);
  begin
    with Result.A['unsupportedChanges'].AddObject do begin S['option'] := Name; S['reason'] := Reason; S['route'] := Route; end;
  end;
begin
  Result := TJsonObject.Create;
  Result.S['sessionRevision'] := UIntToStr(xeAutomationQuerySemanticRevision);
  Result.S['scope'] := 'effective native session globals; changes never write Settings or plugins';
  with Result.O['values'] do begin
    B['alwaysSaveOnam'] := wbAlwaysSaveOnam or wbAlwaysSaveOnamForce;
    B['udrSetXESP'] := wbUDRSetXESP; B['udrSetScale'] := wbUDRSetScale;
    F['udrScaleValue'] := wbUDRSetScaleValue; B['udrSetZ'] := wbUDRSetZ; F['udrZValue'] := wbUDRSetZValue;
    B['udrSetMSTT'] := wbUDRSetMSTT; S['udrMSTTValue'] := IntToHex(wbUDRSetMSTTValue,8);
    B['loadBSAs'] := wbLoadBSAs; B['sortFLST'] := wbSortFLST; B['sortINFO'] := wbSortINFO; B['fillPNAM'] := wbFillPNAM;
    B['clampFormID'] := wbClampFormID; B['resetModifiedOnSave'] := wbResetModifiedOnSave;
    B['manualCleaningAllow'] := wbManualCleaningAllow; B['manualCleaningHide'] := wbManualCleaningHide;
    B['trackAllEditorID'] := wbTrackAllEditorID; S['language'] := wbLanguage;
  end;
  Result.B['alwaysSaveOnamForced'] := wbAlwaysSaveOnamForce;
  Result.S['mutableBooleans'] := 'alwaysSaveOnam,udrSetXESP,udrSetScale,udrSetZ; udrSetMSTT only FO3';
  Result.S['mutableNumbers'] := 'udrScaleValue:0..10; udrZValue:-10000000..10000000; finite native Single values';
  Result.S['effects'] := 'affects later native save/cleaning only; never reruns prior operations; invalidates query/analysis revisions';
  Exclude('loadBSAs,sortFLST,sortINFO,fillPNAM,clampFormID,trackAllEditorID', 'Load/lazy-initialization/index semantics cannot be retroactively applied consistently; configure before a fresh session', 'startup settings');
  Exclude('resetModifiedOnSave', 'Changing native dirty-reset behavior during automation conflicts with the explicit save/flush lifecycle', 'startup settings plus explicit lifecycle validation');
  Exclude('manualCleaningAllow,manualCleaningHide', 'GUI manual-cleaning enable/visibility preferences; use validated cleaning operations', 'cleaning.remove_itm,cleaning.undelete_and_disable_refs');
  Exclude('udrMSTTValue', 'Arbitrary replacement FormID needs native game/master/referrer planning; session options do not establish dependencies', 'explicit references.replace plans');
  Exclude('language', 'Language selection must guard dirty localization caches and reload resources', 'localization.language');
  Exclude('ModGroups', 'Session selection and disk configuration have separate explicit operations', 'modgroups.list,modgroups.activate,modgroups.write');
  Exclude('appearance', 'Fonts/colors/column/layout/tree hiding are GUI presentation preferences', 'GUI Options');
  Exclude('gameLink', 'External watcher startup/shutdown and input-file ownership are not implemented for automation', 'session.game_link read-only discovery');
end;

function xeAutomationSessionSetOptions(const Args: TJsonObject): TJsonObject;
var Values: TJsonObject; Name, Denied: string; i: Integer; Number: Double;
  Dry, Specified, Changed: Boolean; Before: TJsonObject;
begin
  if not Args.Contains('values') or (Args.Types['values'] <> jdtObject) then raise xeAutomationInvalidRequest('values must be an object');
  Values := Args.O['values'];
  if (Values.Count < 1) or (Values.Count > 8) then raise xeAutomationInvalidRequest('Specify 1..8 semantic settings');
  if Args.Contains('expectedSessionRevision') and (xeAutomationRequireStringArg(Args, 'expectedSessionRevision') <> UIntToStr(xeAutomationQuerySemanticRevision)) then
    raise xeAutomationNewError('stale_session_revision', 'Semantic session options changed; reread session.options');
  Dry := xeAutomationReadBooleanArg(Args, 'dryRun', Specified); if not Specified then Dry := True;
  if not Dry and not xeAutomationMutationPolicyConsentSatisfied(Denied) then
    Exit(xeAutomationErrorsBuildConsentRequired('session.set_options', 'session-options', Denied));
  // Validate the whole object before assigning globals. Unknown/startup/forced
  // keys are errors rather than silent partial application of accepted keys.
  for i := 0 to Values.Count - 1 do begin
    Name := Values.Names[i];
    if (Name = 'udrScaleValue') or (Name = 'udrZValue') then begin
      if not (Values.Types[Name] in [jdtInt,jdtLong,jdtULong,jdtFloat]) then raise xeAutomationInvalidRequest('Numeric setting requires a JSON number: ' + Name);
      Number := Values.F[Name];
      if IsNan(Number) or IsInfinite(Number) or (Number < -10000000) or (Number > 10000000) or
        ((Name = 'udrScaleValue') and ((Number < 0) or (Number > 10))) then
        raise xeAutomationInvalidRequest('Numeric setting is outside its advertised range: ' + Name);
    end else if (Name = 'alwaysSaveOnam') or (Name = 'udrSetXESP') or (Name = 'udrSetScale') or
      (Name = 'udrSetZ') or (Name = 'udrSetMSTT') then begin
      if Values.Types[Name] <> jdtBool then raise xeAutomationInvalidRequest('Boolean setting requires a JSON boolean: ' + Name);
      if (Name = 'alwaysSaveOnam') and wbAlwaysSaveOnamForce and not Values.B[Name] then raise xeAutomationStateConflict('alwaysSaveOnam is forced by the native startup mode');
      if (Name = 'udrSetMSTT') and not wbIsFallout3 then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Native UDR MSTT behavior is Fallout3-only');
    end else raise xeAutomationNewError('unsupported_option', 'Setting is unknown or intentionally excluded; inspect session.options: ' + Name);
  end;
  Before := xeAutomationSessionOptions(nil);
  Result := TJsonObject.Create;
  try
    try
      Result.B['dryRun'] := Dry; Result.O['before'].Assign(Before.O['values']); Result.O['requested'].Assign(Values);
      Changed := False;
      for i := 0 to Values.Count - 1 do begin
        Name := Values.Names[i];
        if Name = 'udrScaleValue' then Changed := Changed or (Single(Values.F[Name]) <> wbUDRSetScaleValue)
        else if Name = 'udrZValue' then Changed := Changed or (Single(Values.F[Name]) <> wbUDRSetZValue)
        else Changed := Changed or (Values.B[Name] <> Before.O['values'].B[Name]);
      end;
      if not Dry and Changed then begin
        for i := 0 to Values.Count - 1 do begin
          Name := Values.Names[i];
          if Name = 'alwaysSaveOnam' then wbAlwaysSaveOnam := Values.B[Name] or wbAlwaysSaveOnamForce
          else if Name = 'udrSetXESP' then wbUDRSetXESP := Values.B[Name]
          else if Name = 'udrSetScale' then wbUDRSetScale := Values.B[Name]
          else if Name = 'udrScaleValue' then wbUDRSetScaleValue := Values.F[Name]
          else if Name = 'udrSetZ' then wbUDRSetZ := Values.B[Name]
          else if Name = 'udrZValue' then wbUDRSetZValue := Values.F[Name]
          else if Name = 'udrSetMSTT' then wbUDRSetMSTT := Values.B[Name];
        end;
        xeAutomationInvalidateRecordQueries;
      end;
      Result.B['wouldChange'] := Changed; Result.B['changed'] := not Dry and Changed;
      Result.S['persistence'] := 'session-only native globals; no Settings/plugin write; restart restores configured values';
      Result.O['after'] := xeAutomationSessionOptions(nil);
    except Result.Free; raise; end;
  finally Before.Free; end;
end;

function xeAutomationSessionGameLink(const Args: TJsonObject): TJsonObject;
var Mode: string; Active: Boolean;
begin
  if Args.Contains('mode') then raise xeAutomationNewError('unsupported_game_link_control', 'Automation does not own the external game-link watcher lifecycle; this route is read-only');
  Result := TJsonObject.Create; Result.B['controlSupported'] := False;
  Result.S['reason'] := 'External input-folder/watch-thread start, stop and ownership contracts are intentionally excluded';
  Result.S['nativeAvailability'] := 'TES4 Pluggy; other modes require Data\xEdit\xEditLink.ini; inventory/enchantment/spell are TES4-only';
  Result.B['loadedSession'] := Assigned(frmMain);
  if Assigned(frmMain) then begin
    frmMain.AutomationGetGameLink(Mode, Active);
    Result.S['mode'] := Mode; Result.B['watcherActive'] := Active;
  end;
end;

procedure xeAutomationRegisterSessionCommands;
begin
  xeAutomationRegisterCommand('session.get_dirty_state', xeAutomationSessionGetDirtyState);
  xeAutomationRegisterCommand('session.get_gui_snapshot', xeAutomationSessionGetGuiSnapshot);
  xeAutomationRegisterCommand('session.save', xeAutomationSessionSave);
  xeAutomationRegisterCommand('session.flush', xeAutomationSessionFlush);
  xeAutomationRegisterCommand('session.options', xeAutomationSessionOptions);
  xeAutomationRegisterCommand('session.set_options', xeAutomationSessionSetOptions);
  xeAutomationRegisterCommand('session.game_link', xeAutomationSessionGameLink);
end;

end.
