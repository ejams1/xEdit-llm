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
  Windows, Classes, SysUtils, IniFiles, JsonDataObjects, System.Diagnostics, System.Generics.Collections, wbInterface,
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

procedure xeLODNativeRun(const ADeferInventory: Boolean; const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
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
  lPreviousStrict, lOutputCreated, lPipelineConfigured: Boolean;
  lPreviousInspected, lPreviousScanMax: Integer;
  lPreviousStart: TDateTime;
  lTypes: TLODTypes;
  i: Integer;
begin
  lWorld := xeLODWorld(ATarget.A['worldspaces'].O[0]);
  lRoot := AOptions.S['outputRoot'] + lWorld.EditorID + '\';
  if not ADeferInventory then ASummary.I['worldspaceCount'] := 1;
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
  lPipelineConfigured := False;
  xeLODLogTruncated := False;
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
      lPipelineConfigured := True;
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
    if lPipelineConfigured then lRow.I['inspectedElements'] := wbLODInspectedElements
    else lRow.I['inspectedElements'] := 0;
    lRow.B['outputDirectoryCreated'] := lOutputCreated;
    // Inventory can itself fail after native output exists (for example, a tool
    // creates a reparse point). Preserve the output root and partial-write fact
    // instead of letting the generic job error discard these diagnostics.
    if not ADeferInventory and lOutputCreated then try
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
    if not ADeferInventory and (lRow.S['outcome'] = 'native-returned') then begin
      if lRow.I['generatedFiles'] = 0 then lRow.S['outcome'] := 'no-output'
      else lRow.S['outcome'] := 'generated-needs-independent-verification';
    end;
    ASummary.B['externalOutputWritten'] := ASummary.B['externalOutputWritten'] or lOutputCreated;
    ASummary.B['independentOutputVerificationRequired'] := True;
    if not ADeferInventory then begin
      lFinding := AFindings.AddObject;
      lFinding.S['code'] := 'lod_' + lRow.S['outcome'];
      lFinding.S['editorId'] := lWorld.EditorID;
      lFinding.S['outputRoot'] := lRoot;
    end;
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

const
  xeLODInventoryFileLimit = 1024;
  xeLODInventoryDirectoryLimit = 256;
  xeLODInventoryByteLimit = 262144;
  xeLODInventoryWorkLimit = 16384;
  xeLODInventoryPathLimit = 1024;

type
  TLODInventoryScan = class
  private
    FRoot, FDirectory: string;
    FDirectories: TStack<string>;
    FSearch: TSearchRec;
    FSearchActive, FHaveEntry, FComplete: Boolean;
    FRow: TJsonObject; // Borrowed durable job row; never freed by this cursor.
    FWork, FDirectoryCount, FArtifactBytes: Integer;
    procedure CloseSearch;
  public
    constructor Create(const root: string; const row: TJsonObject);
    destructor Destroy; override;
    function Advance: Boolean;
    procedure WriteProgress(const progress: TJsonObject);
  end;

constructor TLODInventoryScan.Create(const root: string; const row: TJsonObject);
begin
  inherited Create;
  FRoot := root; FRow := row;
  FDirectories := TStack<string>.Create;
  FDirectories.Push(root); FDirectoryCount := 1;
end;

procedure TLODInventoryScan.CloseSearch;
begin
  if FSearchActive then begin FindClose(FSearch); FSearchActive := False; end;
  FHaveEntry := False;
end;

destructor TLODInventoryScan.Destroy;
begin CloseSearch; FDirectories.Free; inherited; end;

function TLODInventoryScan.Advance: Boolean;
var code, bytes: Integer; attrs: DWORD; relative, path: string; artifact: TJsonObject;
begin
  if FComplete then Exit(True);
  if FWork >= xeLODInventoryWorkLimit then
    raise xeAutomationNewError('export_capacity', 'LOD inventory work budget exceeded');
  Inc(FWork);
  if not FSearchActive then begin
    if FDirectories.Count = 0 then begin FComplete := True; Exit(True); end;
    FDirectory := FDirectories.Pop;
    attrs := GetFileAttributes(PChar(ExcludeTrailingPathDelimiter(FDirectory)));
    if attrs = INVALID_FILE_ATTRIBUTES then RaiseLastOSError;
    if (attrs and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
      raise xeAutomationInvalidTarget('Output inventory contains a reparse point');
    if (attrs and FILE_ATTRIBUTE_DIRECTORY) = 0 then
      raise xeAutomationInvalidTarget('Output inventory directory is no longer a directory');
    code := FindFirst(FDirectory + '*', faAnyFile, FSearch);
    if code = 0 then begin FSearchActive := True; FHaveEntry := True; end
    else if code <> ERROR_FILE_NOT_FOUND then
      raise EOSError.CreateFmt('LOD inventory directory enumeration failed (%d)', [code]);
  end else if not FHaveEntry then begin
    code := FindNext(FSearch);
    if code = 0 then FHaveEntry := True
    else begin
      CloseSearch;
      if code <> ERROR_NO_MORE_FILES then
        raise EOSError.CreateFmt('LOD inventory continuation failed (%d)', [code]);
    end;
  end else begin
    FHaveEntry := False;
    if (FSearch.Name <> '.') and (FSearch.Name <> '..') then begin
      if (FSearch.Attr and faSymLink) <> 0 then
        raise xeAutomationInvalidTarget('Output inventory contains a reparse point');
      path := FDirectory + FSearch.Name;
      if Length(path) > xeLODInventoryPathLimit then
        raise xeAutomationNewError('export_capacity', 'LOD inventory path budget exceeded');
      if (FSearch.Attr and faDirectory) <> 0 then begin
        if FDirectoryCount >= xeLODInventoryDirectoryLimit then
          raise xeAutomationNewError('export_capacity', 'LOD inventory directory budget exceeded');
        Inc(FDirectoryCount); FDirectories.Push(IncludeTrailingPathDelimiter(path));
      end else begin
        if FRow.A['artifacts'].Count >= xeLODInventoryFileLimit then
          raise xeAutomationNewError('export_capacity', 'LOD inventory file budget exceeded');
        relative := Copy(path, Length(FRoot) + 1, MaxInt);
        artifact := TJsonObject.Create;
        try
          artifact.S['path'] := relative; artifact.L['bytes'] := FSearch.Size;
          artifact.B['scratch'] := SameText(Copy(relative, 1, 9), '.scratch\');
          bytes := TEncoding.UTF8.GetByteCount(artifact.ToJSON(False)) + 1;
          if FArtifactBytes + bytes > xeLODInventoryByteLimit then
            raise xeAutomationNewError('export_capacity', 'LOD inventory JSON byte budget exceeded');
          FRow.A['artifacts'].AddObject.Assign(artifact); Inc(FArtifactBytes, bytes);
          if not artifact.B['scratch'] then FRow.I['generatedFiles'] := FRow.I['generatedFiles'] + 1;
        finally artifact.Free; end;
      end;
    end;
  end;
  FComplete := not FSearchActive and (FDirectories.Count = 0);
  Result := FComplete;
end;

procedure TLODInventoryScan.WriteProgress(const progress: TJsonObject);
begin
  progress.I['workUnits'] := FWork; progress.I['workLimit'] := xeLODInventoryWorkLimit;
  progress.I['directoriesSeen'] := FDirectoryCount; progress.I['directoryLimit'] := xeLODInventoryDirectoryLimit;
  progress.I['pendingDirectories'] := FDirectories.Count;
  progress.I['artifactCount'] := FRow.A['artifacts'].Count; progress.I['fileLimit'] := xeLODInventoryFileLimit;
  progress.I['artifactBytes'] := FArtifactBytes; progress.I['byteLimit'] := xeLODInventoryByteLimit;
  progress.I['pathLimit'] := xeLODInventoryPathLimit;
  progress.B['complete'] := FComplete;
  progress.S['validity'] := 'observed enumeration only; no filesystem snapshot or content verification';
end;

type
  TLODStepper = class(TxeAutomationJobStepper)
  private
    FTarget, FOptions, FNativeFailure, FInventoryFailure, FInventoryProgress: TJsonObject;
    FRow: TJsonObject;
    FScan: TLODInventoryScan;
    FDry, FSpecified, FComplete: Boolean;
    FPhase: string;
    FSteps, FLastWork, FNativeUnits: Integer;
    procedure Finalize(const findings: TJsonArray; const summary, failure: TJsonObject);
  public
    constructor Create(const dry, specified: Boolean; const target, options: TJsonObject);
    destructor Destroy; override;
    function Advance(const findings: TJsonArray; const summary, resultData, failure: TJsonObject): Boolean; override;
    procedure WriteProgress(const progress: TJsonObject); override;
  end;

constructor TLODStepper.Create(const dry, specified: Boolean; const target, options: TJsonObject);
begin
  inherited Create;
  FDry := dry; FSpecified := specified; FTarget := target.Clone; FOptions := options.Clone;
  FNativeFailure := TJsonObject.Create; FInventoryFailure := TJsonObject.Create;
  FInventoryProgress := TJsonObject.Create; FPhase := 'native-pipeline';
end;

destructor TLODStepper.Destroy;
begin
  FScan.Free; FTarget.Free; FOptions.Free; FNativeFailure.Free;
  FInventoryFailure.Free; FInventoryProgress.Free; inherited;
end;

procedure TLODStepper.Finalize(const findings: TJsonArray; const summary, failure: TJsonObject);
var finding: TJsonObject;
begin
  // Preserve the native failure as primary when inventory also fails.
  if FNativeFailure.Count > 0 then failure.Assign(FNativeFailure)
  else if FInventoryFailure.Count > 0 then failure.Assign(FInventoryFailure);
  if FRow.S['outcome'] = 'native-returned' then begin
    if failure.Count > 0 then FRow.S['outcome'] := 'failed'
    else if FRow.I['generatedFiles'] = 0 then FRow.S['outcome'] := 'no-output'
    else FRow.S['outcome'] := 'generated-needs-independent-verification';
  end;
  finding := TJsonObject.Create;
  try
    finding.S['code'] := 'lod_' + FRow.S['outcome']; finding.S['editorId'] := FRow.S['editorId'];
    finding.S['outputRoot'] := FRow.S['outputRoot'];
    xeAutomationAppendJobFinding(findings, finding); finding := nil;
  finally finding.Free; end;
  FComplete := failure.Count = 0; FRow.B['complete'] := FComplete;
  if FComplete then summary.I['completedWorldspaces'] := summary.I['completedWorldspaces'] + 1;
  FPhase := 'complete';
end;

function TLODStepper.Advance(const findings: TJsonArray;
  const summary, resultData, failure: TJsonObject): Boolean;
var timer: TStopwatch; rowCount: Integer;
begin
  Inc(FSteps); FLastWork := 0;
  try
    if FPhase = 'native-pipeline' then begin
      rowCount := resultData.A['worldspaces'].Count;
      FLastWork := 1;
      if not FDry then Inc(FNativeUnits);
      try
        xeLODNativeRun(True, '', FDry, FSpecified, FTarget, FOptions, findings, summary, resultData, FNativeFailure);
      finally
        if resultData.A['worldspaces'].Count > rowCount then begin
          FRow := resultData.A['worldspaces'].O[rowCount];
          FRow.B['complete'] := False; FRow.B['inventoryComplete'] := False;
          FRow.B['nativeComplete'] := not FDry;
          summary.I['worldspaceCount'] := summary.I['worldspaceCount'] + 1;
          if not summary.Contains('completedWorldspaces') then summary.I['completedWorldspaces'] := 0;
          summary.S['cancelBoundary'] := 'after indivisible native world pipeline; between output inventory actions';
        end;
      end;
      if FDry then begin
        FComplete := True; FRow.B['complete'] := True; FPhase := 'complete';
        summary.I['completedWorldspaces'] := summary.I['completedWorldspaces'] + 1;
      end else begin
        if FNativeFailure.Count > 0 then FRow.O['nativeFailure'].Assign(FNativeFailure);
        FPhase := 'finalize';
        if FRow.B['outputDirectoryCreated'] then begin
          FScan := TLODInventoryScan.Create(FRow.S['outputRoot'], FRow);
          FScan.WriteProgress(FInventoryProgress); FPhase := 'output-inventory';
        end;
      end;
      // Always expose a cancellation boundary before inventory/final reporting.
      Exit(FComplete);
    end;
    if FPhase = 'output-inventory' then begin
      timer := TStopwatch.StartNew;
      try
        try
          while (FLastWork < xeAutomationJobStepWorkLimit) and
            (timer.ElapsedMilliseconds < xeAutomationJobStepBudgetMs) do begin
            Inc(FLastWork);
            if FScan.Advance then begin
              FRow.B['inventoryComplete'] := True; FPhase := 'finalize'; Break;
            end;
          end;
        except
          on E: Exception do begin
            FRow.B['inventoryTruncated'] := True; FRow.S['inventoryError'] := Copy(E.Message, 1, 4096);
            if E is ExeAutomationError then FInventoryFailure.S['code'] := ExeAutomationError(E).Code
            else FInventoryFailure.S['code'] := 'lod_inventory_failed';
            FInventoryFailure.S['message'] := FRow.S['inventoryError'];
            FInventoryFailure.S['phase'] := 'output-inventory';
            FInventoryFailure.S['outputRoot'] := FRow.S['outputRoot'];
            FInventoryFailure.B['partialKnown'] := False;
            FPhase := 'finalize';
          end;
        end;
      finally
        FScan.WriteProgress(FInventoryProgress);
        if FPhase = 'finalize' then FreeAndNil(FScan);
      end;
      Exit(False);
    end;
    FLastWork := 1; Finalize(findings, summary, failure);
  except
    on E: Exception do begin
      if Assigned(FRow) then begin FRow.S['outcome'] := 'failed'; FRow.B['complete'] := False; end;
      if failure.Count = 0 then begin
        if E is ExeAutomationError then failure.S['code'] := ExeAutomationError(E).Code
        else failure.S['code'] := 'lod_generation_failed';
        failure.S['message'] := Copy(E.Message, 1, 4096); failure.S['phase'] := FPhase;
        if Assigned(FRow) then failure.S['outputRoot'] := FRow.S['outputRoot'];
        failure.B['partialKnown'] := False;
      end;
      FreeAndNil(FScan);
    end;
  end;
  Result := FComplete;
end;

procedure TLODStepper.WriteProgress(const progress: TJsonObject);
begin
  progress.S['phase'] := FPhase; progress.I['steps'] := FSteps;
  progress.I['lastWorkUnits'] := FLastWork; progress.I['workLimit'] := xeAutomationJobStepWorkLimit;
  progress.I['softBudgetMs'] := xeAutomationJobStepBudgetMs;
  progress.I['nativeUnits'] := FNativeUnits; progress.I['nativeUnitLimit'] := 1;
  progress.B['stageComplete'] := FComplete;
  progress.B['nativeCallsPreemptible'] := False;
  progress.B['nativeFailurePending'] := FNativeFailure.Count > 0;
  if Assigned(FRow) then progress.S['editorId'] := FRow.S['editorId'];
  if FInventoryProgress.Count > 0 then progress.O['inventory'].Assign(FInventoryProgress);
  progress.S['nativeAtoms'] := 'entire native world pipeline and external tool wait; individual filesystem enumeration calls';
end;

function NewLODStepper(const kind: string; const dry, specified: Boolean;
  const target, options: TJsonObject): TxeAutomationJobStepper;
begin Result := TLODStepper.Create(dry, specified, target, options); end;

procedure xeLODRun(const AJobId: string; const ADryRun, ADryRunSpecified: Boolean;
  const ATarget, AOptions: TJsonObject; const AFindings: TJsonArray;
  const ASummary, AResult, AFailure: TJsonObject);
begin
  xeLODNativeRun(False, AJobId, ADryRun, ADryRunSpecified, ATarget, AOptions,
    AFindings, ASummary, AResult, AFailure);
end;

procedure xeAutomationRegisterLODJobs;
begin
  xeAutomationRegisterJobKindWithValidator('lod.generate', xeLODRun, xeLODValidateStart, 'worldspaces');
  xeAutomationRegisterJobStepper('lod.generate', NewLODStepper);
end;

end.
