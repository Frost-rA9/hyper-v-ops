# Start the VM and wait for the unattended install to finish.
#
# Success means PowerShell Direct answers, not that the VM state or the disk
# size looks right. The install has no visible screen, so disk growth is a
# progress hint only.
# With a blank password, LimitBlankPasswordUse must be 0 inside the guest.
# Otherwise the guest refuses the network logon that PowerShell Direct uses.
# The answer file in media/ already sets it.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$User,
  [int]$TimeoutMinutes = 35
)

$ErrorActionPreference = 'Continue'
$cred = New-Object System.Management.Automation.PSCredential($User, (New-Object System.Security.SecureString))

$vm = Get-VM -Name $Name
if ($vm.State -ne 'Running') {
  Write-Output "Starting VM: $Name"
  Start-VM -Name $Name
  Start-Sleep -Seconds 5
}

$vhd = (Get-VMHardDiskDrive -VMName $Name | Where-Object { $_.ControllerLocation -eq 0 }).Path
$started = Get-Date
$attempt = 0

while ($true) {
  $attempt++
  $elapsed = [int]((Get-Date) - $started).TotalSeconds
  if ($elapsed -gt $TimeoutMinutes * 60) { Write-Output 'Timed out'; break }

  $state = (Get-VM -Name $Name).State
  $sizeGB = 0
  try { $sizeGB = [math]::Round((Get-Item -LiteralPath $vhd).Length / 1GB, 2) } catch { }
  Write-Output ("[{0,5}s] attempt {1}  state={2}  disk={3} GB" -f $elapsed, $attempt, $state, $sizeGB)

  if ($state -eq 'Off') { Write-Output 'VM powered off. The install most likely failed.'; break }

  # Six minutes without a write means the guest never reached the installer.
  # The usual cause is a boot image that waits for a keypress.
  if ($elapsed -gt 360 -and $sizeGB -lt 1) {
    Write-Output 'No disk write in six minutes. Check that the boot image has no key prompt.'
    break
  }

  try {
    $r = Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop -ScriptBlock {
      [pscustomobject]@{
        Computer  = $env:COMPUTERNAME
        User      = "$env:USERDOMAIN\$env:USERNAME"
        OS        = (Get-CimInstance Win32_OperatingSystem).Caption
        Build     = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        Displays  = (@(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ' | ')
      }
    }
    Write-Output 'Install finished. PowerShell Direct answers.'
    $r | Format-List
    break
  } catch {
    $msg = $_.Exception.Message -replace '\s+', ' '
    Write-Output ('  ' + $msg.Substring(0, [Math]::Min(110, $msg.Length)))
  }
  Start-Sleep -Seconds 15
}
