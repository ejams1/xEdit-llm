{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationProjection;
interface
uses JsonDataObjects, Types;
function xeAutomationProjectionFieldNames: TStringDynArray;
procedure xeAutomationValidateProjection(const AArgs: TJsonObject);
procedure xeAutomationProjectResponse(const AResponse, AArgs: TJsonObject);
implementation
uses SysUtils, xeAutomationObjectModel, xeAutomationErrors;

const
  AllowedFields = ',kind,signature,formId,path,name,editorId,fullName,displayNameKey,isMaster,isDeleted,isWinningOverride,overrideCount,hasChildren,value,editValue,nativeValue,valueSummary,elementType,defType,canEdit,canRemove,previewMetadata,storageEncoding,';

function xeAutomationProjectionFieldNames: TStringDynArray;
var lFields: string;
begin
  lFields := Copy(AllowedFields, 2, Length(AllowedFields) - 2);
  Result := lFields.Split([',']);
end;

procedure xeAutomationValidateProjection(const AArgs: TJsonObject);
var
  lFields: TStringDynArray;
  lField: string;
  lSpecified: Boolean;
begin
  if AArgs.Contains('fields') then begin
    lFields := xeAutomationReadStringArrayArg(AArgs, 'fields');
    if Length(lFields) > 32 then
      raise xeAutomationInvalidRequest('fields is limited to 32 summary fields');
    for lField in lFields do
      if (lField = '') or (Pos(',' + lField + ',', AllowedFields) = 0) then
        raise xeAutomationInvalidRequest('Unknown summary projection field: ' + lField);
  end;
  xeAutomationReadBooleanArg(AArgs, 'includeRelations', lSpecified);
end;

procedure xeAutomationProjectResponse(const AResponse, AArgs: TJsonObject);
var
  lFields: TStringDynArray;
  lProject, lRelations, lSpecified: Boolean;

  function Keep(const AName: string): Boolean;
  var
    lField: string;
  begin
    Result := (AName = 'kind') or (AName = 'formId') or (AName = 'path');
    for lField in lFields do
      if lField = AName then
        Exit(True);
  end;

  procedure Walk(const ANode: TJsonBaseObject; const ADepth: Integer);
  var
    lObject, lSummary: TJsonObject;
    lArray: TJsonArray;
    i: Integer;
  begin
    if ADepth > 64 then
      raise xeAutomationInvalidRequest('Projected response exceeds the nesting limit');
    if ANode is TJsonObject then begin
      lObject := TJsonObject(ANode);
      // Only locator+summary wrappers are protocol objects. Arbitrary value
      // maps can legitimately contain keys called object or relations.
      if lObject.Contains('locator') and (lObject.Types['locator'] = jdtObject) and
         lObject.Contains('object') and (lObject.Types['object'] = jdtObject) and
         lObject.O['object'].Contains('kind') then begin
        if not lRelations then
          lObject.Remove('relations');
        if lProject then begin
          lSummary := lObject.O['object'];
          for i := lSummary.Count - 1 downto 0 do
            if not Keep(lSummary.Names[i]) then
              lSummary.Delete(i);
        end;
      end;
      // Locators and completeness/revision/outcome fields are always retained;
      // projection only removes optional summary fields and relation blocks.
      for i := 0 to lObject.Count - 1 do
        case lObject.Types[lObject.Names[i]] of
          jdtObject: Walk(lObject.O[lObject.Names[i]], ADepth + 1);
          jdtArray: Walk(lObject.A[lObject.Names[i]], ADepth + 1);
        end;
    end else if ANode is TJsonArray then begin
      lArray := TJsonArray(ANode);
      for i := 0 to lArray.Count - 1 do
        case lArray.Types[i] of
          jdtObject: Walk(lArray.O[i], ADepth + 1);
          jdtArray: Walk(lArray.A[i], ADepth + 1);
        end;
    end;
  end;
begin
  lProject := AArgs.Contains('fields');
  lFields := xeAutomationReadStringArrayArg(AArgs, 'fields');
  lRelations := xeAutomationReadBooleanArg(AArgs, 'includeRelations', lSpecified);
  if not lSpecified then
    lRelations := True;
  if lProject or not lRelations then
    Walk(AResponse, 0);
end;
end.
