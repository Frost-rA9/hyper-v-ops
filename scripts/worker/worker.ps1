# hyperv-ops elevated worker.
#
# Started once through UAC. Stays alive until .worker\stop.txt appears.
# Every job is executed in a fresh child powershell that inherits this
# elevated token, so a crashing job cannot take the worker down.
#
# Protocol
#   in    .worker\jobs\<id>.ps1      job script (UTF-8, BOM optional)
#   out   .worker\out\<id>.log       stdout + stderr, UTF-8
#         .worker\out\<id>.json      metadata, written last (completion marker)
#         .worker\out\<id>.ps1       the executed script, kept as a record
#   ctrl  .worker\heartbeat.txt      rewritten on every poll
#         .worker\stop.txt           create it to shut the worker down
#         .worker\worker.log         worker level events
#
# A job may declare a timeout on its first line:  #TIMEOUT: 1800  (seconds)
#
# Trust boundary: the worker runs every *.ps1 in the jobs folder with its
# elevated token, and it passes -ExecutionPolicy Bypass to each child process.
# Any account that can write to that folder can therefore run code as
# administrator. Use the worker on a single-user machine.

param(
  [string]$Root,
  [int]$PollMs = 300,
  [string]$WorkDir
)

# The worker keeps its queue next to the repository, not at a fixed path.
# The script lives in scripts/worker, so the repository root is two levels up.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Root)    { $Root = Join-Path $repoRoot '.worker' }
if (-not $WorkDir) { $WorkDir = $repoRoot }

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$PSDefaultParameterValues['*:ErrorAction'] = 'Continue'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom   = New-Object System.Text.UTF8Encoding($true)

$JobsDir   = Join-Path $Root 'jobs'
$ActiveDir = Join-Path $Root 'active'
$OutDir    = Join-Path $Root 'out'
foreach ($d in @($Root, $JobsDir, $ActiveDir, $OutDir)) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$WorkerLog = Join-Path $Root 'worker.log'
function WriteText([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}
function Log([string]$Message) {
  $line = '{0} {1}' -f (Get-Date).ToString('HH:mm:ss.fff'), $Message
  [IO.File]::AppendAllText($WorkerLog, $line + "`r`n", $utf8NoBom)
}

# --- single instance -------------------------------------------------------
$LockPath = Join-Path $Root 'worker.lock'
if (Test-Path -LiteralPath $LockPath) {
  $oldPid = 0
  [void][int]::TryParse((Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue), [ref]$oldPid)
  if ($oldPid -gt 0 -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
    Log "abort: worker already running as pid $oldPid"
    [Environment]::Exit(2)
  }
}
WriteText $LockPath "$PID"

# --- identify the token we run with ----------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
              [Security.Principal.WindowsBuiltInRole]::Administrator)
try { $Host.UI.RawUI.WindowTitle = "hyperv-ops worker (Do Not Close) pid=$PID" } catch { }

$startup = @"
hyperv-ops worker started
  pid      : $PID
  user     : $($identity.Name)
  elevated : $isAdmin
  psver    : $($PSVersionTable.PSVersion)
  root     : $Root
"@
WriteText (Join-Path $Root 'worker.status.txt') $startup
Log "started pid=$PID user=$($identity.Name) elevated=$isAdmin"

if (-not $isAdmin) {
  Write-Host 'NOT ELEVATED - jobs will fail. Exiting.' -ForegroundColor Red
  Log 'abort: not elevated'
  Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
  [Environment]::Exit(3)
}

# --- job runner ------------------------------------------------------------
$RunnerHeader = @'
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location -LiteralPath '__WORKDIR__'
$__jobOk = $true
$__jobExit = 0
try {
'@

$RunnerFooter = @'
} catch {
  $__jobOk = $false
  [Console]::Error.WriteLine('JOB-EXCEPTION: ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message)
  [Console]::Error.WriteLine($_.ScriptStackTrace)
}
if (-not $__jobOk) { exit 1 }
if ($null -ne $LASTEXITCODE) { $__jobExit = [int]$LASTEXITCODE }
exit $__jobExit
'@

function Invoke-Job([string]$JobFile) {
  $id     = [IO.Path]::GetFileNameWithoutExtension($JobFile)
  $actPath = Join-Path $ActiveDir ($id + '.ps1')
  $runPath = Join-Path $ActiveDir ($id + '.run.ps1')

  try { Move-Item -LiteralPath $JobFile -Destination $actPath -Force -ErrorAction Stop }
  catch { return }

  $startedUtc = (Get-Date).ToUniversalTime().ToString('o')
  $source = [IO.File]::ReadAllText($actPath, [Text.Encoding]::UTF8)

  $timeoutSec = 900
  if ($source -match '(?m)^#\s*TIMEOUT\s*:\s*(\d+)') { $timeoutSec = [int]$Matches[1] }

  $runner = $RunnerHeader.Replace('__WORKDIR__', $WorkDir) + $source + "`r`n" + $RunnerFooter
  # Written with a BOM: PowerShell 5.1 falls back to the ANSI codepage on BOM-less
  # files, which corrupts non-ASCII literals such as a Chinese VM name.
  [IO.File]::WriteAllText($runPath, $runner, $utf8Bom)

  Log "job start $id timeout=${timeoutSec}s"
  Write-Host ("[{0}] running {1}" -f (Get-Date).ToString('HH:mm:ss'), $id) -ForegroundColor Cyan

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $psi.Arguments              = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $runPath
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
  $psi.WorkingDirectory       = $WorkDir

  $proc = $null
  $timedOut = $false
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($timeoutSec * 1000)) {
      $timedOut = $true
      try { $proc.Kill() } catch { }
      Start-Sleep -Milliseconds 300
      $proc.WaitForExit(5000) | Out-Null
    }
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    if ($timedOut) { $exitCode = -1 } else { $exitCode = $proc.ExitCode }
  } catch {
    $stdout = ''
    $stderr = 'WORKER-ERROR: ' + $_.Exception.Message
    $exitCode = -2
  } finally {
    if ($proc) { try { $proc.Dispose() } catch { } }
  }

  $finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
  $logText = @"
== job      : $id
== started  : $startedUtc
== finished : $finishedUtc
== exit     : $exitCode
== timed out: $timedOut
== timeout  : ${timeoutSec}s
---- STDOUT ----
$stdout
---- STDERR ----
$stderr
"@
  WriteText (Join-Path $OutDir ($id + '.log')) $logText

  $meta = [ordered]@{
    id          = $id
    exit        = $exitCode
    timedOut    = $timedOut
    startedUtc  = $startedUtc
    finishedUtc = $finishedUtc
    durationMs  = [int](((Get-Date).ToUniversalTime()) - [datetime]::Parse($startedUtc).ToUniversalTime()).TotalMilliseconds
    stdoutBytes = $stdout.Length
    stderrBytes = $stderr.Length
  }
  WriteText (Join-Path $OutDir ($id + '.json')) ($meta | ConvertTo-Json -Depth 4)

  Move-Item -LiteralPath $actPath -Destination (Join-Path $OutDir ($id + '.ps1')) -Force -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $runPath -Destination (Join-Path $OutDir ($id + '.run.ps1')) -Force -ErrorAction SilentlyContinue

  Log "job done  $id exit=$exitCode timedOut=$timedOut"
  Write-Host ("[{0}] done    {1} exit={2}" -f (Get-Date).ToString('HH:mm:ss'), $id, $exitCode) -ForegroundColor Green
}

# --- main loop -------------------------------------------------------------
$StopPath = Join-Path $Root 'stop.txt'
$seq = 0
Log 'loop started'
while ($true) {
  $seq++
  WriteText (Join-Path $Root 'heartbeat.txt') ("{0}`t{1}`t{2}" -f (Get-Date).ToUniversalTime().ToString('o'), $PID, $seq)

  if (Test-Path -LiteralPath $StopPath) {
    Log "stop requested after $seq polls"
    Write-Host 'stop.txt found - shutting down.' -ForegroundColor Yellow
    break
  }

  $pending = @(Get-ChildItem -LiteralPath $JobsDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  foreach ($job in $pending) { Invoke-Job $job.FullName }

  Start-Sleep -Milliseconds $PollMs
}

Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
WriteText (Join-Path $Root 'worker.status.txt') ("stopped at " + (Get-Date).ToString('o'))
Log 'exited'
# The worker is normally started with -NoExit so that a crash keeps its window
# readable. That also keeps the process alive after the script ends, which would
# wedge any relaunch helper waiting on our pid. Kill the process explicitly.
[Environment]::Exit(0)
