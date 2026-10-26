# Copy the host display driver into the guest (guest side).
#
# The partition device reports the hardware ID PCI\VEN_1414&DEV_008E. That ID
# belongs to a Microsoft synthetic device and binds to vrd.inf. The vendor INF
# has no entry for it, so installing the package with pnputil binds nothing.
# Three locations must be filled to move the device from Code 43 to OK:
#   1. the whole package into System32\HostDriverStore\FileRepository\
#   2. the nv*.dll files from the package into System32\
#   3. nvlddmkm.sys into System32\drivers\
# Without steps 2 and 3 the device keeps reporting Code 43.
param(
  [Parameter(Mandatory)][string]$PackagePath,
  [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'

$pkgName = Split-Path -Leaf $PackagePath
$src = $PackagePath
if (-not (Test-Path -LiteralPath (Join-Path $src 'nv_dispi.inf'))) {
  throw "No nv_dispi.inf in $src"
}

$sys32 = Join-Path $env:SystemRoot 'System32'
$hostStore = Join-Path $sys32 'HostDriverStore\FileRepository'
$drivers = Join-Path $sys32 'drivers'
$dst = Join-Path $hostStore $pkgName

New-Item -ItemType Directory -Path $hostStore -Force | Out-Null
& robocopy.exe $src $dst /E /MT:16 /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
Write-Output ('Package copied: ' + $dst)

& robocopy.exe $src $sys32 'nv*.dll' /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
Write-Output 'User-mode DLLs copied to System32'

$kmd = Get-ChildItem -LiteralPath $src -Filter 'nvlddmkm.sys' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($kmd) {
  Copy-Item -LiteralPath $kmd.FullName -Destination $drivers -Force
  Write-Output ('Kernel driver copied: ' + (Join-Path $drivers 'nvlddmkm.sys'))
} else {
  Write-Output 'Warning: the package has no nvlddmkm.sys'
}

& pnputil.exe /scan-devices | Out-Null
Start-Sleep -Seconds 8

Write-Output '=== Display devices ==='
Get-PnpDevice -Class Display | Select-Object Status, Problem, FriendlyName, InstanceId | Format-Table -AutoSize -Wrap

# Each re-attach of the partition adapter on the host leaves one phantom device
# behind. Phantom devices do not affect the stream.
Write-Output '=== Phantom devices ==='
$phantoms = @(Get-PnpDevice -Class Display | Where-Object { $_.Status -eq 'Unknown' })
Write-Output ("Count: " + $phantoms.Count)
foreach ($p in $phantoms) { Write-Output ('  ' + $p.InstanceId) }

if (-not $NoReboot) {
  Write-Output 'Restarting the guest to load the driver'
  Restart-Computer -Force
}
