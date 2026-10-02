{******************************************************************************

  This Source Code Form is subject to the terms of the Mozilla Public License,
  v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain
  one at https://mozilla.org/MPL/2.0/.

*******************************************************************************}

unit xeAutomationWireLimits;

interface

const
  xeAutomationMaxRequestBytes = 4 * 1024 * 1024;
  xeAutomationMaxResponseBytes = 4 * 1024 * 1024;
  xeAutomationCorrelationMaxBytes = 512;
  xeAutomationIdempotencyKeyMaxBytes = 128;
  xeAutomationReadDeadlineMs = 15000;
  xeAutomationWriteDeadlineMs = 15000;
  xeAutomationPeerCloseDeadlineMs = 3000;
  xeAutomationClientResponseDeadlineMs = 60000;
  xeAutomationReplayMaxEntries = 128;
  xeAutomationReplayMaxBytes = 32 * 1024 * 1024;

implementation

end.
