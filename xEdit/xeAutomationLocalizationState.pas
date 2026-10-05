{******************************************************************************
  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.
*******************************************************************************}
unit xeAutomationLocalizationState;
interface
uses JsonDataObjects;
var xeAutomationLocalizationRestartRequired: Boolean;
procedure xeAutomationAssertLocalizationCommandAllowed(const ACommand: string);
procedure xeAutomationWriteLocalizationDirtyState(const AResult: TJsonObject);
function xeAutomationLocalizationHasDirtyTables: Boolean;
implementation
uses SysUtils, wbLocalization, xeAutomationErrors;

function xeAutomationLocalizationHasDirtyTables: Boolean;
var i: Integer;
begin
  Result := False;
  for i := 0 to wbLocalizationHandler.Count - 1 do
    if wbLocalizationHandler[i].Modified then Exit(True);
end;

procedure xeAutomationWriteLocalizationDirtyState(const AResult: TJsonObject);
var i: Integer;
begin
  AResult.A['dirtyLocalizationTables'].Clear;
  for i := 0 to wbLocalizationHandler.Count - 1 do
    if wbLocalizationHandler[i].Modified then AResult.A['dirtyLocalizationTables'].Add(wbLocalizationHandler[i].Name);
  AResult.I['dirtyLocalizationTableCount'] := AResult.A['dirtyLocalizationTables'].Count;
  AResult.B['localizationRestartRequired'] := xeAutomationLocalizationRestartRequired;
end;

procedure xeAutomationAssertLocalizationCommandAllowed(const ACommand: string);
var lName: string;
begin
  if not xeAutomationLocalizationRestartRequired then Exit;
  lName := LowerCase(Trim(ACommand));
  if (Copy(lName, 1, 7) = 'system.') or (lName = 'session.get_dirty_state') or
     (lName = 'session.save') or (lName = 'session.flush') or
     (lName = 'localization.tables') or (lName = 'localization.get') or
     (lName = 'localization.save') or (lName = 'localization.export_text') or
     (lName = 'files.get') or (lName = 'files.get_header') then Exit;
  // Native conversion changes element representation and intentionally closes
  // the GUI. Permit only persistence/diagnostics until the daemon is restarted.
  raise xeAutomationStateConflict('Localization conversion requires table save, plugin save, terminal flush and restart before further work');
end;
end.
