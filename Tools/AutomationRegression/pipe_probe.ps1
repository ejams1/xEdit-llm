param(
  [Parameter(Mandatory)][int]$DaemonPid,
  [string]$Request,
  [string]$Response,
  [ValidateSet('call','stall','disconnect','no-read')][string]$Mode = 'call',
  [int]$HoldMs = 18000
)
$ErrorActionPreference = 'Stop'
# Async .NET owns its pending buffers until completion/cancellation. Disposing
# the stream on a deadline also covers peers that never complete a message.
$pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', "xedit-$DaemonPid",
  [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
try {
  $pipe.Connect(5000)
  $pipe.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message
  if ($Mode -eq 'stall') { Start-Sleep -Milliseconds $HoldMs; return }
  $bytes = [System.IO.File]::ReadAllBytes($Request)
  $write = $pipe.WriteAsync($bytes, 0, $bytes.Length)
  if (-not $write.Wait(15000)) { throw 'probe write deadline exceeded' }
  $write.GetAwaiter().GetResult()
  if ($Mode -eq 'disconnect') { return }
  if ($Mode -eq 'no-read') { Start-Sleep -Milliseconds $HoldMs; return }
  $result = [System.IO.MemoryStream]::new()
  try {
    $buffer = [byte[]]::new(65536)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    do {
      $remaining = 60000 - [int]$timer.ElapsedMilliseconds
      if ($remaining -le 0) { throw 'probe response deadline exceeded' }
      $read = $pipe.ReadAsync($buffer, 0, $buffer.Length)
      if (-not $read.Wait($remaining)) { throw 'probe response deadline exceeded' }
      $count = $read.GetAwaiter().GetResult()
      if ($count -eq 0) { throw 'peer closed without a complete response' }
      if ($result.Length + $count -gt 4194304) { throw 'unbounded peer response' }
      $result.Write($buffer, 0, $count)
    } until ($pipe.IsMessageComplete)
    [System.IO.File]::WriteAllBytes($Response, $result.ToArray())
  } finally { $result.Dispose() }
} finally { $pipe.Dispose() }
