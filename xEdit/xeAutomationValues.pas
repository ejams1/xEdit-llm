{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationValues;

interface

uses
  JsonDataObjects,
  wbInterface;

procedure xeAutomationWriteFullValues(const ATarget: TJsonObject; const AElement: IwbElement);
procedure xeAutomationWritePreviewMetadata(const ATarget: TJsonObject; const AOriginal, APreview: string);

implementation

uses
  SysUtils,
  Variants,
  Math,
  TypInfo,
  xeAutomationErrors;

const
  xeAutomationFullValueMaxCharacters = 1048576;
  xeAutomationNativeArrayMaxItems = 50000;

procedure xeAutomationWritePreviewMetadata(const ATarget: TJsonObject; const AOriginal, APreview: string);
begin
  ATarget.I['length'] := Length(AOriginal);
  ATarget.S['lengthUnit'] := 'utf16-code-units';
  ATarget.I['previewLength'] := Length(APreview);
  ATarget.B['whitespaceRemoved'] := Trim(AOriginal) <> AOriginal;
  ATarget.B['truncated'] := Length(Trim(AOriginal)) > Length(APreview);
  ATarget.B['lossless'] := AOriginal = APreview;
end;

procedure xeAutomationWriteNativeValue(const ATarget: TJsonObject; const AValue: Variant);
var
  lType, i, lLow, lHigh: Integer;
begin
  lType := VarType(AValue);
  ATarget.I['variantType'] := lType;
  ATarget.B['available'] := True;
  ATarget.B['truncated'] := False;
  if VarIsArray(AValue) then begin
    ATarget.S['kind'] := 'array';
    ATarget.I['dimensions'] := VarArrayDimCount(AValue);
    if VarArrayDimCount(AValue) <> 1 then
      raise xeAutomationInvalidRequest('Full native read supports one-dimensional Variant arrays only');
    lLow := VarArrayLowBound(AValue, 1);
    lHigh := VarArrayHighBound(AValue, 1);
    if Int64(lHigh) - lLow + 1 > xeAutomationNativeArrayMaxItems then
      raise xeAutomationInvalidRequest('Full native array exceeds the 50000-item read limit');
    ATarget.I['lowerBound'] := lLow;
    ATarget.I['length'] := lHigh - lLow + 1;
    ATarget.A['items'].Clear;
    for i := lLow to lHigh do
      xeAutomationWriteNativeValue(ATarget.A['items'].AddObject, AValue[i]);
    Exit;
  end;
  case lType and varTypeMask of
    varEmpty, varNull: begin
      ATarget.S['kind'] := 'null';
      ATarget['value'] := nil;
    end;
    varByte, varShortInt, varSmallint, varWord, varInteger, varLongWord, varInt64, varUInt64: begin
      ATarget.S['kind'] := 'integer';
      // Decimal text preserves all 64 bits through JSON clients using doubles.
      ATarget.S['representation'] := 'decimal-string';
      ATarget.S['value'] := VarToStr(AValue);
    end;
    varSingle, varDouble: begin
      ATarget.S['kind'] := 'float';
      if IsNan(Double(AValue)) or IsInfinite(Double(AValue)) then
        ATarget.S['value'] := VarToStr(AValue)
      else
        ATarget.F['value'] := AValue;
    end;
    varCurrency: begin
      ATarget.S['kind'] := 'decimal';
      ATarget.S['representation'] := 'decimal-string';
      ATarget.S['value'] := CurrToStr(Currency(AValue), TFormatSettings.Invariant);
    end;
    varDate: begin
      ATarget.S['kind'] := 'date';
      ATarget.S['representation'] := 'ole-date-double';
      ATarget.F['value'] := Double(AValue);
    end;
    varBoolean: begin
      ATarget.S['kind'] := 'boolean';
      ATarget.B['value'] := AValue;
    end;
    varOleStr, varString, varUString: begin
      ATarget.S['kind'] := 'string';
      if Length(string(AValue)) > xeAutomationFullValueMaxCharacters then
        raise xeAutomationInvalidRequest('Full string exceeds the 1048576-character read limit');
      ATarget.S['value'] := AValue;
      ATarget.I['length'] := Length(string(AValue));
      ATarget.S['lengthUnit'] := 'utf16-code-units';
    end;
  else
    ATarget.B['available'] := False;
    ATarget.S['kind'] := 'unsupported';
    ATarget.S['reason'] := 'Native Variant cannot be represented losslessly by this contract';
  end;
end;

procedure xeAutomationWriteFullValues(const ATarget: TJsonObject; const AElement: IwbElement);
var
  lEdit: string;
  lStringDef: IwbBaseStringDef;
  lData: IwbDataContainer;
  lEncoding: TEncoding;
begin
  lEdit := AElement.EditValue;
  if Length(lEdit) > xeAutomationFullValueMaxCharacters then
    raise xeAutomationInvalidRequest('Full edit value exceeds the 1048576-character read limit');
  ATarget.S['editValue'] := lEdit;
  ATarget.I['length'] := Length(lEdit);
  ATarget.S['lengthUnit'] := 'utf16-code-units';
  ATarget.S['jsonEncoding'] := 'utf-8';
  ATarget.I['utf8Bytes'] := TEncoding.UTF8.GetByteCount(lEdit);
  ATarget.B['truncated'] := False;
  ATarget.B['whitespacePreserved'] := True;
  if Assigned(AElement.ResolvedValueDef) then
    ATarget.S['definitionType'] := GetEnumName(TypeInfo(TwbDefType), Ord(AElement.ResolvedValueDef.DefType));
  xeAutomationWriteNativeValue(ATarget.O['nativeValue'], AElement.NativeValue);
  ATarget.O['storageEncoding'].B['available'] := False;
  if Supports(AElement.ResolvedValueDef, IwbBaseStringDef, lStringDef) and
     Supports(AElement, IwbDataContainer, lData) then begin
    // Localized IDs are not inline text; avoid claiming their binary storage
    // encoding is the encoding of the external localized string table.
    if (AElement.ResolvedValueDef.DefType = dtLString) and
       Assigned(AElement._File) and AElement._File.IsLocalized then begin
      ATarget.O['storageEncoding'].S['reason'] := 'localized-string-table';
    end else begin
      lEncoding := lStringDef.EffectiveEncoding(lData.DataBasePtr, lData.DataEndPtr, AElement);
      ATarget.O['storageEncoding'].B['available'] := True;
      ATarget.O['storageEncoding'].I['codePage'] := lEncoding.CodePage;
      ATarget.O['storageEncoding'].S['name'] := lEncoding.EncodingName;
    end;
  end;
end;

end.
