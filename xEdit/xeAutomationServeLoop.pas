{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationServeLoop;

interface

function xeAutomationServeLoopPipeName: string;
function xeAutomationServeLoopExitRequested: Boolean;
procedure xeAutomationServeLoopStart;
procedure xeAutomationServeLoopStop;
procedure xeAutomationServeLoopPoll;
procedure xeAutomationServeLoopRequestExit;

implementation

uses
  xeAutomationCommandsBatch,
  xeAutomationCommandsFormIds,
  xeAutomationCommandsPatches,
  xeAutomationCommandsCleaning,
  xeAutomationCommandsFileHygiene,
  xeAutomationCommandsJobs,
  xeAutomationCommandsLOD,
  xeAutomationCommandsReachability,
  xeAutomationCommandsLocalization,
  xeAutomationCommandsModGroups,
  xeAutomationCommandsVWD,
  xeAutomationCommandsReports,
  xeAutomationCommandsSelections,
  xeAutomationCommandsPluginAnalysis,
  xeAutomationCommandsValidation,
  xeAutomationCommandsSession,
  xeAutomationCommandsSessionNavigation,
  Windows,
  Messages,
  Classes,
  Forms,
  SysUtils,
  xeAutomationCommandsElements,
  xeAutomationCommandsExports,
  xeAutomationCommandsFiles,
  xeAutomationCommandsRecords,
  xeAutomationCommandsScripts,
  Generics.Collections,
  xeAutomationPipeExchange,
  xeAutomationReplay,
  xeAutomationRecordQueries,
  xeAutomationHostCli,
  xeAutomationTransportPipe;

var
  xeAutomationServeActive: Boolean;
  xeAutomationServeCommandsRegistered: Boolean;
  xeAutomationServeExitRequested: Boolean;
  xeAutomationServePipeNameValue: string;
  xeAutomationServeExchange: TxeAutomationPipeExchange;
  xeAutomationRetiredExchanges: TObjectList<TxeAutomationPipeExchange>;
  xeAutomationServePolling, xeAutomationClosePosted: Boolean;

function xeAutomationServeLoopPipeName: string;
begin
  Result := xeAutomationServePipeNameValue;
end;

function xeAutomationServeLoopExitRequested: Boolean;
begin
  Result := xeAutomationServeExitRequested;
end;

procedure xeAutomationServeLoopRequestExit;
begin
  // Exit blocks command admission, while the current response continues through
  // bounded write/peer-close states after session.flush releases the graph.
  xeAutomationServeExitRequested := True;
end;

procedure xeAutomationRetireExchange;
begin
  if not Assigned(xeAutomationServeExchange) then
    Exit;
  xeAutomationServeExchange.Close;
  if xeAutomationServeExchange.Retired then
    FreeAndNil(xeAutomationServeExchange)
  else begin
    xeAutomationRetiredExchanges.Add(xeAutomationServeExchange);
    xeAutomationServeExchange := nil;
  end;
end;

procedure xeAutomationCollectRetiredExchanges;
var
  i: Integer;
begin
  for i := xeAutomationRetiredExchanges.Count - 1 downto 0 do
    if xeAutomationRetiredExchanges[i].Retired then
      xeAutomationRetiredExchanges.Delete(i);
end;

procedure xeAutomationServeLoopStart;
begin
  xeAutomationServeLoopStop;
  // Serve mode owns the loaded-data command surface. Register it exactly once
  // here, after xEdit finishes loading the real session, so one-shot CLI stays
  // stateless and duplicate registration mistakes still fail loudly.
  if not xeAutomationServeCommandsRegistered then begin
    xeAutomationRegisterSessionCommands;
    // Navigation is loaded-session-only because it drives the live main form
    // through xEdit's native JumpTo seam instead of a headless data lookup.
    xeAutomationRegisterSessionNavigationCommands;
    xeAutomationRegisterFilesCommands;
    // Loaded-data daemon sessions must expose file hygiene before any capabilities
    // probe, because direct callers may invoke these commands immediately by PID.
    xeAutomationRegisterFileHygieneCommands;
    // Plugin analysis is read-only but depends on loaded files, so daemon startup
    // wires it beside file hygiene before job commands/capabilities are queried.
    xeAutomationRegisterPluginAnalysisCommands;
    // Validation jobs are loaded-data read-only checks. Register them before the
    // job command facade so daemon capabilities and jobs.start agree immediately.
    xeAutomationRegisterValidationCommands;
    // 6D cleaning jobs share loaded xEdit state and must be registered before the
    // job facade so jobs.start and capabilities observe the same implemented set.
    xeAutomationRegisterCleaningCommands;
    xeAutomationRegisterLODJobs;
    xeAutomationRegisterReachabilityJobs;
    xeAutomationRegisterLocalizationCommands;
    xeAutomationRegisterModGroupCommands;
    xeAutomationRegisterVWDCommands;
    xeAutomationRegisterReportCommands;
    xeAutomationRegisterSelectionCommands;
    xeAutomationRegisterRecordsCommands;
    xeAutomationRegisterElementsCommands;
    xeAutomationRegisterBatchCommands;
    xeAutomationRegisterFormIdCommands;
    xeAutomationRegisterPatchCommands;
    xeAutomationRegisterExportCommands;
    // Scripts run against loaded data and locator resolution, so expose them only
    // after the session/files/records/elements command surface has been wired.
    xeAutomationRegisterScriptsCommands;
    // Job commands are registered after file hygiene so the batch job kind is
    // visible to both lifecycle commands and the capabilities response.
    xeAutomationRegisterJobsCommands;
    xeAutomationServeCommandsRegistered := True;
  end;
  xeAutomationServeExitRequested := False;
  xeAutomationClosePosted := False;
  xeAutomationReplayBeginSession;
  xeAutomationServeActive := True;
  xeAutomationServePipeNameValue := xeAutomationPipeNameForPid(GetCurrentProcessId);
  xeAutomationServeExchange := TxeAutomationPipeExchange.Create(xeAutomationServePipeNameValue);
end;

procedure xeAutomationServeLoopStop;
begin
  xeAutomationInvalidateRecordQueries;
  xeAutomationServeActive := False;
  xeAutomationRetireExchange;
  xeAutomationServePipeNameValue := '';
  xeAutomationReplayEndSession;
end;

procedure xeAutomationServeLoopPoll;
var
  lResponseText: string;
  lExecutingExchange: TxeAutomationPipeExchange;
begin
  // Native commands/scripts may pump VCL messages. A timer reentry must never
  // execute the same completed request again or overwrite pending I/O storage.
  if not xeAutomationServeActive or xeAutomationServePolling then
    Exit;
  xeAutomationServePolling := True;
  try
    xeAutomationCollectRetiredExchanges;
    if not Assigned(xeAutomationServeExchange) and not xeAutomationServeExitRequested then
      xeAutomationServeExchange := TxeAutomationPipeExchange.Create(xeAutomationServePipeNameValue);
    if Assigned(xeAutomationServeExchange) then begin
      try
        xeAutomationServeExchange.Poll;
        if xeAutomationServeExchange.Phase = xpExecute then begin
          if xeAutomationServeExitRequested then
            xeAutomationServeExchange.Close
          else begin
            lExecutingExchange := xeAutomationServeExchange;
            try
              lResponseText := xeAutomationExecuteRequestText(xeAutomationServeExchange.RequestText);
            except
              on E: Exception do
                lResponseText := xeAutomationBuildTransportErrorText('invalid_request', E.Message, False);
            end;
            // Dispatch may pump messages and stop the server. The saved pointer
            // is only an identity token; Stop may already have freed its object.
            if xeAutomationServeActive and
               (xeAutomationServeExchange = lExecutingExchange) then
              xeAutomationServeExchange.Respond(lResponseText);
          end;
        end;
      except
        // Peer loss or malformed transport affects only this exchange. Host
        // execution errors are already serialized and replayed before delivery.
        if Assigned(xeAutomationServeExchange) then
          xeAutomationServeExchange.Close;
      end;
      if Assigned(xeAutomationServeExchange) and (xeAutomationServeExchange.Phase = xpDone) then
        xeAutomationRetireExchange;
    end;
    if xeAutomationServeExitRequested and not Assigned(xeAutomationServeExchange) and
       not xeAutomationClosePosted then begin
      xeAutomationClosePosted := True;
      if Assigned(Application.MainForm) then begin
        if not PostMessage(Application.MainForm.Handle, WM_CLOSE, 0, 0) then
          Application.Terminate;
      end else
        Application.Terminate;
    end;
  finally
    xeAutomationServePolling := False;
  end;
end;

initialization
  xeAutomationRetiredExchanges := TObjectList<TxeAutomationPipeExchange>.Create(True);
finalization
  xeAutomationServeLoopStop;
  xeAutomationCollectRetiredExchanges;
  // Kernel cancellation need not have retired during process teardown. Keep
  // remaining I/O-owned buffers alive until the OS ends the process rather than
  // freeing an OVERLAPPED or buffer that may still be referenced by the kernel.
  xeAutomationRetiredExchanges.OwnsObjects := False;
  xeAutomationRetiredExchanges.Free;
end.
