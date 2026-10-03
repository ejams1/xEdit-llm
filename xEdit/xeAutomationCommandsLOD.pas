{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationCommandsLOD;

interface

procedure xeAutomationRegisterLODJobs;

implementation

uses
  Classes, SysUtils, IniFiles, JsonDataObjects, System.Generics.Collections, wbInterface,
  wbImplementation, wbLoadOrder, wbHelpers, wbLOD, ImagingTypes, xeAutomationDataLookup,
  xeAutomationErrors, xeAutomationJobs, xeAutomationObjectModel;

var
  xeLODLog: TJsonArray;
  xeLODLogTruncated: Boolean;

procedure xeLODProgress(const AStatus: string);
begin
  // Native callbacks and console output can be large. Retain bounded diagnostics
  // without allowing an external tool to exhaust the job reply budget.
  if not Assigned(xeLODLog) or (AStatus = '') then Exit;
  if xeLODLog.Count < 100 then xeLODLog.Add(Copy(AStatus, 1, 512))
  else xeLODLogTruncated := True;
  if Length(AStatus) > 512 then xeLODLogTruncated := True;
end;

function xeLODBoolean(const AArgs: TJsonObject; const AName: string; ADefault: Boolean): Boolean;
var lSpecified: Boolean;
begin
  Result := xeAutomationReadBooleanArg(AArgs, AName, lSpecified);
  if not lSpecified then Result := ADefault;
end;

function xeLODInteger(const AArgs: TJsonObject; const AName: string;
  ADefault, AMin, AMax: Integer): Integer;
begin
  Result := ADefault;
  if not AArgs.Contains(AName) then Exit;
  if not (AArgs.Types[AName] in [jdtInt, jdtLong, jdtULong]) or
     (AArgs.L[AName] < AMin) or (AArgs.L[AName] > AMax) then
    raise xeAutomationInvalidRequest('LOD setting ' + AName + ' is outside its integer bounds');
  Result := AArgs.I[AName];
end;

procedure xeLODValidateName(const AName: string);
var c: Char;
begin
  if (AName = '') or (Length(AName) > 64) then raise xeAutomationInvalidTarget('Worldspace EDID must contain 1..64 filename characters');
  for c in AName do
    if not CharInSet(c, ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      raise xeAutomationInvalidTarget('Worldspace EDID contains unsafe output-path characters');
end;

function xeLODWorld(const ALocator: TJsonObject): IwbMainRecord;
var lLocator: TxeAutomationLocator;
begin
  lLocator := xeAutomationParseLocator(ALocator, True, False);
  if lLocator.Path <> '' then raise xeAutomationInvalidRequest('LOD targets must be WRLD root records');
  Result := xeAutomationRequireMainRecord(lLocator).WinningOverride;
  if (Result.Signature <> 'WRLD') or Result.IsDeleted then raise xeAutomationInvalidTarget('LOD target must be a live WRLD');
  xeLODValidateName(Result.EditorID);
  xeLODValidateName(Result.MasterOrSelf.EditorID);
  if Result.ElementExists['Parent\WNAM'] and ((Result.ElementNativeValues['Parent\PNAM\Flags'] and $2) <> 0) then
    raise xeAutomationInvalidTarget('Worldspace uses its parent LOD data');
end;

procedure xeLODValidateStart(var ADryRun: Boolean; const ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject);
var
  lRoot, lDrive, lOperation, lKey: string;
  lSettings: TJsonObject;
  lWorld: IwbMainRecord;
  lSeen: TStringList;
  lResources: TDynResources;
  lLodSettings: TwbLodSettings;
  lObjects, lTrees, lSplit: Boolean;
  i, lValue: Integer;
begin
  if not ADryRunSpecified then ADryRun := True;
  if not Assigned(AOptions) then raise xeAutomationInvalidRequest('LOD options with outputRoot are required');
  if not Assigned(ATarget) then raise xeAutomationInvalidRequest('LOD worldspace targets are required');
  if not ((wbGameMode = gmTES4) or wbIsSkyrim or wbIsFallout3 or wbIsFallout4) then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'LOD supports TES4, Skyrim-family, FO3/FNV and FO4-family games; FO76/Starfield reject');
  if not ATarget.Contains('worldspaces') or (ATarget.Types['worldspaces'] <> jdtArray) or
     (ATarget.A['worldspaces'].Count < 1) or (ATarget.A['worldspaces'].Count > 4) then
    raise xeAutomationInvalidRequest('target.worldspaces must contain 1..4 WRLD locators');
  lOperation := 'generate';
  if AOptions.Contains('operation') then lOperation := xeAutomationRequireStringArg(AOptions, 'operation');
  if (lOperation <> 'generate') and (lOperation <> 'splitAtlas') then
    raise xeAutomationInvalidRequest('LOD operation must be generate or splitAtlas');
  lSplit := lOperation = 'splitAtlas';
  if lSplit and not (wbIsSkyrim or wbIsFallout3) then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Split LOD Atlas supports Skyrim and FO3/FNV only');
  lObjects := xeLODBoolean(AOptions, 'objects', not lSplit);
  lTrees := xeLODBoolean(AOptions, 'trees', not lSplit and (wbIsSkyrim or wbIsFallout3));
  if lSplit and (lObjects or lTrees) then raise xeAutomationInvalidRequest('Split Atlas cannot be combined with generation flags');
  if not lSplit and not (lObjects or lTrees) then raise xeAutomationInvalidRequest('Select objects or trees');
  if lTrees and not (wbIsSkyrim or wbIsFallout3) then raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'Traditional tree LOD is unsupported in this game');
  if lObjects and (wbGameMode in [gmSSE, gmTES5VR, gmEnderalSE]) and (wbToolMode <> tmLODGen) then
    raise xeAutomationNewError(xeAutomationErrorUnsupportedGameMode, 'SSE/VR/EnderalSE object LOD requires native LODGen startup mode');
  if AOptions.Contains('settings') and (AOptions.Types['settings'] <> jdtObject) then
    raise xeAutomationInvalidRequest('options.settings must be an object');
  lSettings := AOptions.O['settings'];
  for i := 0 to lSettings.Count - 1 do begin
    lKey := lSettings.Names[i];
    if (lKey <> 'atlasWidth') and (lKey <> 'atlasHeight') and (lKey <> 'textureSize') and
       (lKey <> 'brightness') and (lKey <> 'alphaThreshold') and (lKey <> 'trees3D') and
       (lKey <> 'noTangents') and (lKey <> 'noVertexColors') and (lKey <> 'lodLevel') and
       (lKey <> 'x') and (lKey <> 'y') then raise xeAutomationInvalidRequest('Unknown LOD setting: ' + lKey);
  end;
  for i := 0 to 1 do begin
    if i = 0 then lKey := 'atlasWidth' else lKey := 'atlasHeight';
    if wbIsFallout4 then lValue := 4096 else lValue := 2048;
    lValue := xeLODInteger(lSettings, lKey, lValue, 1024, 8192);
    if (lValue and (lValue - 1)) <> 0 then raise xeAutomationInvalidRequest('Atlas dimensions must be powers of two');
    lSettings.I[lKey] := lValue;
  end;
  lValue := xeLODInteger(lSettings, 'textureSize', 512, 256, 1024);
  if (lValue <> 256) and (lValue <> 512) and (lValue <> 1024) then raise xeAutomationInvalidRequest('textureSize must be 256, 512 or 1024');
  lSettings.I['textureSize'] := lValue;
  lSettings.I['brightness'] := xeLODInteger(lSettings, 'brightness', 0, -30, 30);
  lSettings.I['alphaThreshold'] := xeLODInteger(lSettings, 'alphaThreshold', 128, 0, 255);
  lSettings.B['trees3D'] := xeLODBoolean(lSettings, 'trees3D', False);
  lSettings.B['noTangents'] := xeLODBoolean(lSettings, 'noTangents', False);
  lSettings.B['noVertexColors'] := xeLODBoolean(lSettings, 'noVertexColors', wbIsFallout3);
  if lSettings.B['trees3D'] and not (lObjects and wbIsSkyrim) then raise xeAutomationInvalidRequest('trees3D requires Skyrim object LOD');
  if lSettings.Contains('lodLevel') then begin
    lValue := xeLODInteger(lSettings, 'lodLevel', 4, 4, 16);
    if not (lValue in [4, 8, 16]) then raise xeAutomationInvalidRequest('lodLevel must be 4, 8 or 16');
  end;
  if lSettings.Contains('x') <> lSettings.Contains('y') then raise xeAutomationInvalidRequest('LOD chunk x and y must be supplied together');
  if lSettings.Contains('x') then begin
    xeLODInteger(lSettings, 'x', 0, -32768, 32767);
    xeLODInteger(lSettings, 'y', 0, -32768, 32767);
    if not lSettings.Contains('lodLevel') then raise xeAutomationInvalidRequest('LOD chunk coordinates require lodLevel');
  end;
  if wbIsFallout3 then begin
    lSettings.I['textureSize'] := 1024;
    lSettings.B['noTangents'] := False;
    lSettings.B['noVertexColors'] := True;
  end;
  lRoot := xeAutomationRequireStringArg(AOptions, 'outputRoot');
  lDrive := ExtractFileDrive(lRoot);
  if (lDrive = '') or (Length(lRoot) > 160) or (Length(lRoot) <= Length(lDrive)) or
     (lRoot[Length(lDrive) + 1] <> '\') then raise xeAutomationInvalidRequest('outputRoot must be an absolute existing directory <=160 characters');
  lRoot := IncludeTrailingPathDelimiter(ExpandFileName(lRoot));
  if not DirectoryExists(lRoot) then raise xeAutomationInvalidTarget('outputRoot must already exist');
  AOptions.S['outputRoot'] := lRoot;
  AOptions.S['operation'] := lOperation;
  AOptions.B['objects'] := lObjects;
  AOptions.B['trees'] := lTrees;
  if not ADryRun and lObjects and (wbGameMode <> gmTES4) and not FileExists(wbScriptsPath + sLODGenName) then
    raise xeAutomationInvalidTarget('Native LODGen tool is missing from the scripts directory');
  lSeen := TStringList.Create;
  try
    for i := 0 to ATarget.A['worldspaces'].Count - 1 do begin
      if ATarget.A['worldspaces'].Types[i] <> jdtObject then raise xeAutomationInvalidRequest('Each worldspace must be a locator object');
      lWorld := xeLODWorld(ATarget.A['worldspaces'].O[i]);
      if lSeen.IndexOf(LowerCase(lWorld.EditorID)) >= 0 then raise xeAutomationInvalidRequest('Worldspaces must have distinct output EDIDs');
      lSeen.Add(LowerCase(lWorld.EditorID));
      if DirectoryExists(lRoot + lWorld.EditorID) or FileExists(lRoot + lWorld.EditorID) then
        raise xeAutomationStateConflict('World output already exists; use a fresh output root');
      if wbGameMode <> gmTES4 then begin
        lResources := wbContainerHandler.OpenResource(wbLODSettingsFileName(lWorld.EditorID));
        if Length(lResources) = 0 then raise xeAutomationInvalidTarget('Worldspace LOD settings resource is missing');
        lLodSettings.Init;
        lLodSettings.LoadFromData(lResources[High(lResources)].GetData);
        if (lLodSettings.Stride < 1) or (lLodSettings.Stride > 256) or
           (lLodSettings.LODLevelMin < 1) or (lLodSettings.LODLevelMax > 32) or
           (lLodSettings.LODLevelMax < lLodSettings.LODLevelMin) then
          raise xeAutomationInvalidTarget('Worldspace LOD settings exceed supported bounds');
      end;
    end;
  finally lSeen.Free; end;
end;

procedure xeLODInventory(const ARoot: string; const ARow: TJsonObject);
var
  lDirectories: TStack<string>;
  lDirectory, lRelative: string;
  lSearch: TSearchRec;
  lArtifact: TJsonObject;
  lCount: Integer;
begin
  lDirectories := TStack<string>.Create;
  try
    lDirectories.Push(ARoot);
    lCount := 0;
    while lDirectories.Count > 0 do begin
      lDirectory := lDirectories.Pop;
      if FindFirst(lDirectory + '*', faAnyFile, lSearch) = 0 then try
        repeat
          if (lSearch.Name = '.') or (lSearch.Name = '..') then Continue;
          if (lSearch.Attr and faSymLink) <> 0 then raise xeAutomationInvalidTarget('Output inventory contains a reparse point');
          if (lSearch.Attr and faDirectory) <> 0 then begin
            if lDirectories.Count >= 256 then raise xeAutomationNewError('export_capacity', 'LOD output directory budget exceeded');
            lDirectories.Push(lDirectory + lSearch.Name + '\');
          end else begin
            Inc(lCount);
            if lCount > 1024 then begin ARow.B['inventoryTruncated'] := True; Exit; end;
            lRelative := Copy(lDirectory + lSearch.Name, Length(ARoot) + 1, MaxInt);
            lArtifact := ARow.A['artifacts'].AddObject;
            lArtifact.S['path'] := lRelative;
            lArtifact.L['bytes'] := lSearch.Size;
            lArtifact.B['scratch'] := SameText(Copy(lRelative, 1, 9), '.scratch\');
            if not lArtifact.B['scratch'] then ARow.I['generatedFiles'] := ARow.I['generatedFiles'] + 1;
          end;
        until FindNext(lSearch) <> 0;
      finally FindClose(lSearch); end;
    end;
  finally lDirectories.Free; end;
end;

procedure xeLODRun(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray;
  const ASummary, AResult, AFailure: TJsonObject);
var
  lWorld: IwbMainRecord;
  lFiles: TwbFiles;
  lModules: TwbModuleInfos;
  lFile: IwbFile;
  lSettings: TMemIniFile;
  lJsonSettings, lRow, lFinding: TJsonObject;
  lRoot, lPreviousOutput, lPreviousTemp, lPreviousScratch, lSection, lPhase: string;
  lPreviousProgress: TwbProgressCallback;
  lPreviousStrict, lOutputCreated: Boolean;
  lPreviousInspected, lPreviousScanMax: Integer;
  lPreviousStart: TDateTime;
  lTypes: TLODTypes;
  i: Integer;
begin
  lWorld := xeLODWorld(ATarget.A['worldspaces'].O[0]);
  lRoot := AOptions.S['outputRoot'] + lWorld.EditorID + '\';
  ASummary.I['worldspaceCount'] := 1;
  ASummary.S['persistence'] := 'immediate-external-output; plugins-unchanged';
  ASummary.S['cancelBoundary'] := 'between-worldspaces; native-unit-blocks-current-poll';
  lRow := AResult.A['worldspaces'].AddObject;
  lRow.S['editorId'] := lWorld.EditorID;
  lRow.S['formId'] := lWorld.LoadOrderFormID.ToString(False);
  lRow.S['operation'] := AOptions.S['operation'];
  lRow.S['outputRoot'] := lRoot;
  lRow.A['artifacts'].Clear;
  lRow.I['generatedFiles'] := 0;
  lRow.O['settings'].Assign(AOptions.O['settings']);
  if ADryRun then begin lRow.S['outcome'] := 'planned'; Exit; end;
  if DirectoryExists(lRoot) or FileExists(ExcludeTrailingPathDelimiter(lRoot)) then
    raise xeAutomationStateConflict('World output appeared after planning; use a fresh root');
  lSettings := TMemIniFile.Create('');
  lPreviousOutput := wbOutputPath;
  lPreviousTemp := wbTempPath;
  lPreviousScratch := wbLODScratchPath;
  lPreviousStrict := wbLODStrictAutomation;
  lPreviousProgress := _wbProgressCallback;
  lPreviousStart := wbStartTime;
  lPreviousInspected := wbLODInspectedElements;
  lPreviousScanMax := wbLODMaxScanElements;
  lOutputCreated := False;
  try
    lPhase := 'create-output';
    try
      // Fresh per-world output avoids deleting/replacing earlier generated files.
      // Native binaries stay in scripts; all mutable exports/temp use this root.
      if not CreateDir(ExcludeTrailingPathDelimiter(lRoot)) then RaiseLastOSError;
      lOutputCreated := True;
      wbOutputPath := lRoot;
      wbLODScratchPath := lRoot + '.scratch\';
      wbTempPath := wbLODScratchPath + 'temp\';
      if not ForceDirectories(wbTempPath) then RaiseLastOSError;
      wbLODStrictAutomation := True;
      wbLODInspectedElements := 0;
      wbLODMaxScanElements := 100000;
      _wbProgressCallback := xeLODProgress;
      xeLODLog := lRow.A['log'];
      xeLODLogTruncated := False;
      wbStartTime := Now;
      lJsonSettings := AOptions.O['settings'];
      lSection := wbAppName + ' LOD Options';
      lSettings.WriteBool(lSection, 'BuildAtlas', True);
      lSettings.WriteInteger(lSection, 'AtlasWidth', lJsonSettings.I['atlasWidth']);
      lSettings.WriteInteger(lSection, 'AtlasHeight', lJsonSettings.I['atlasHeight']);
      lSettings.WriteInteger(lSection, 'AtlasTextureSize', lJsonSettings.I['textureSize']);
      lSettings.WriteInteger(lSection, 'TreesBrightness', lJsonSettings.I['brightness']);
      lSettings.WriteInteger(lSection, 'DefaultAlphaThreshold', lJsonSettings.I['alphaThreshold']);
      lSettings.WriteBool(lSection, 'Trees3D', lJsonSettings.B['trees3D']);
      lSettings.WriteBool(lSection, 'ObjectsNoTangents', lJsonSettings.B['noTangents']);
      lSettings.WriteBool(lSection, 'ObjectsNoVertexColors', lJsonSettings.B['noVertexColors']);
      lSettings.WriteInteger(lSection, 'AtlasSpecularFormat', Integer(ifATI2n));
      if wbIsFallout4 then begin
        lSettings.WriteInteger(lSection, 'AtlasDiffuseFormat', Integer(ifDXT5));
        lSettings.WriteInteger(lSection, 'AtlasNormalFormat', Integer(ifATI2n));
        lSettings.WriteString(lSection, 'AtlasTextureUVRange', '1.1');
      end else begin
        lSettings.WriteInteger(lSection, 'AtlasDiffuseFormat', Integer(ifDXT3));
        lSettings.WriteInteger(lSection, 'AtlasNormalFormat', Integer(ifDXT1));
        lSettings.WriteString(lSection, 'AtlasTextureUVRange', '1.5');
      end;
      if wbIsFallout3 then lSettings.WriteString(lSection, 'AtlasTextureUVRange', '10000');
      if lJsonSettings.Contains('lodLevel') then begin
        lSettings.WriteBool(lSection, 'Chunk', True);
        lSettings.WriteInteger(lSection, 'LODLevel', lJsonSettings.I['lodLevel']);
      end;
      if lJsonSettings.Contains('x') then begin
        lSettings.WriteBool(lSection, 'Chunk', True);
        lSettings.WriteInteger(lSection, 'LODX', lJsonSettings.I['x']);
        lSettings.WriteInteger(lSection, 'LODY', lJsonSettings.I['y']);
      end;
      lModules := wbModulesByLoadOrder;
      for i := Low(lModules) to High(lModules) do begin
        lFile := xeAutomationTryPluginFileFromModule(lModules[i]);
        if Assigned(lFile) then begin SetLength(lFiles, Length(lFiles) + 1); lFiles[High(lFiles)] := lFile; end;
      end;
      lTypes := [];
      if AOptions.B['objects'] then Include(lTypes, lodObjects);
      if AOptions.B['trees'] then Include(lTypes, lodTrees);
      lPhase := 'native-pipeline';
      if AOptions.S['operation'] = 'splitAtlas' then wbSplitTreeLOD(lWorld, lFiles)
      else if wbGameMode = gmTES4 then wbGenerateLODTES4(lWorld, lSettings)
      else if wbIsFallout4 then wbGenerateLODFO4(lWorld, lFiles, lSettings)
      else wbGenerateLODTES5(lWorld, lTypes, lFiles, lSettings);
      lRow.S['outcome'] := 'native-returned';
    except
      on E: Exception do begin
        lRow.S['outcome'] := 'failed';
        AFailure.S['code'] := 'lod_generation_failed';
        AFailure.S['message'] := E.Message;
        AFailure.S['phase'] := lPhase;
        AFailure.S['outputRoot'] := lRoot;
        AFailure.B['partialKnown'] := False;
      end;
    end;
    lRow.B['logTruncated'] := xeLODLogTruncated;
    lRow.I['inspectedElements'] := wbLODInspectedElements;
    lRow.B['outputDirectoryCreated'] := lOutputCreated;
    // Inventory can itself fail after native output exists (for example, a tool
    // creates a reparse point). Preserve the output root and partial-write fact
    // instead of letting the generic job error discard these diagnostics.
    if lOutputCreated then try
      xeLODInventory(lRoot, lRow);
    except
      on E: Exception do begin
        lRow.B['inventoryTruncated'] := True;
        lRow.S['inventoryError'] := E.Message;
        if AFailure.S['code'] = '' then begin
          lRow.S['outcome'] := 'failed';
          AFailure.S['code'] := 'lod_inventory_failed';
          AFailure.S['message'] := E.Message;
          AFailure.S['phase'] := 'output-inventory';
          AFailure.S['outputRoot'] := lRoot;
          AFailure.B['partialKnown'] := False;
        end;
      end;
    end;
    if lRow.S['outcome'] = 'native-returned' then begin
      if lRow.I['generatedFiles'] = 0 then lRow.S['outcome'] := 'no-output'
      else lRow.S['outcome'] := 'generated-needs-independent-verification';
    end;
    ASummary.B['externalOutputWritten'] := lOutputCreated;
    ASummary.B['independentOutputVerificationRequired'] := True;
    lFinding := AFindings.AddObject;
    lFinding.S['code'] := 'lod_' + lRow.S['outcome'];
    lFinding.S['editorId'] := lWorld.EditorID;
    lFinding.S['outputRoot'] := lRoot;
  finally
    xeLODLog := nil;
    _wbProgressCallback := lPreviousProgress;
    wbLODStrictAutomation := lPreviousStrict;
    wbLODScratchPath := lPreviousScratch;
    wbOutputPath := lPreviousOutput;
    wbTempPath := lPreviousTemp;
    wbStartTime := lPreviousStart;
    wbLODInspectedElements := lPreviousInspected;
    wbLODMaxScanElements := lPreviousScanMax;
    lSettings.Free;
  end;
end;

procedure xeAutomationRegisterLODJobs;
begin
  xeAutomationRegisterJobKindWithValidator('lod.generate', xeLODRun, xeLODValidateStart, 'worldspaces');
end;

end.
