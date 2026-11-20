# Prunes the worker output folder.
#
# A job is identified by its <id>.json, which the worker writes last. A missing
# .json means the job was still running when the worker left, so this script
# leaves those files alone.
#
# Usage
#   scripts\worker\prune.ps1                 keep the newest 20 jobs
#   scripts\worker\prune.ps1 -Keep 5         keep the newest 5 jobs
#   scripts\worker\prune.ps1 -WhatIf         report without deleting

[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$Root,
  [int]$Keep = 20
)

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Root) { $Root = Join-Path $repoRoot '.worker' }

$OutDir = Join-Path $Root 'out'
if (-not (Test-Path -LiteralPath $OutDir)) { throw "No out folder: $OutDir" }

$jobs = foreach ($json in Get-ChildItem -LiteralPath $OutDir -Filter '*.json' -File) {
  $finished = $null
  try { $finished = (Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json).finishedUtc } catch { }
  if ($finished) { $key = [datetime]::Parse($finished, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() }
  else           { $key = $json.LastWriteTimeUtc }
  [pscustomobject]@{
    Id  = [IO.Path]::GetFileNameWithoutExtension($json.Name)
    Key = $key
  }
}

$ordered = @($jobs | Sort-Object Key -Descending)
$drop    = @($ordered | Select-Object -Skip $Keep)

'out folder      : ' + $OutDir
'jobs with json  : ' + $ordered.Count
'keep newest     : ' + [math]::Min($Keep, $ordered.Count)
'remove          : ' + $drop.Count

$removed = 0
foreach ($job in $drop) {
  foreach ($ext in '.json', '.log', '.ps1', '.run.ps1') {
    $path = Join-Path $OutDir ($job.Id + $ext)
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if ($PSCmdlet.ShouldProcess($path, 'Remove')) {
      Remove-Item -LiteralPath $path -Force
      $removed++
    }
  }
}
'files removed   : ' + $removed
