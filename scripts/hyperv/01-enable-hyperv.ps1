# Enable the Hyper-V features this setup needs.
#
# hypervisorlaunchtype auto keeps the host itself running on Hyper-V.
# Emulators that need raw VT-x (some Android emulators, older VMware builds)
# then fail to start. To restore them, run
# `bcdedit /set hypervisorlaunchtype off` and restart.
$ErrorActionPreference = 'Stop'

$features = @(
  'Microsoft-Hyper-V-All',
  'HypervisorPlatform',
  'VirtualMachinePlatform'
)

foreach ($f in $features) {
  $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
  Write-Output ("{0,-32} {1}" -f $f, $state)
  if ($state -ne 'Enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart | Out-Null
    Write-Output ("{0,-32} enabled" -f $f)
  }
}

& bcdedit.exe /set hypervisorlaunchtype auto | Out-Null
Write-Output 'hypervisorlaunchtype = auto'

$pending = (Get-WindowsOptionalFeature -Online | Where-Object { $_.RestartNeeded }).Count
if ($pending -gt 0) {
  Write-Output "Restart required. $pending features wait for it."
} else {
  Write-Output 'No restart required.'
}
