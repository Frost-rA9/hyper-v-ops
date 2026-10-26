# Connect to the VM.
#
# VMConnect needs administrator rights, and the window captures the mouse.
# For headless work use PowerShell Direct instead. It runs over VMBus and does
# not need a network path into the guest.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$User,
  [switch]$UseVmConnect
)

$ErrorActionPreference = 'Stop'

Write-Output '=== VM state ==='
Get-VM -Name $Name | Select-Object Name, State, ProcessorCount,
  @{n='MemGB';e={[int]($_.MemoryStartup/1GB)}} | Format-List

if ($UseVmConnect) {
  Write-Output 'Opening VMConnect. The window captures the mouse until you release it with Ctrl+Alt+Left Arrow.'
  Start-Process -FilePath 'vmconnect.exe' -ArgumentList @('localhost', $Name) -Verb RunAs
  return
}

Write-Output '=== PowerShell Direct ==='
$cred = New-Object System.Management.Automation.PSCredential($User, (New-Object System.Security.SecureString))
try {
  Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop -ScriptBlock {
    [pscustomobject]@{
      Computer = $env:COMPUTERNAME
      User     = "$env:USERDOMAIN\$env:USERNAME"
      OS       = (Get-CimInstance Win32_OperatingSystem).Caption
      IP       = (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '192.168.*' } |
                   ForEach-Object { $_.IPAddress }) -join ',')
    }
  } | Format-List
} catch {
  Write-Output ('PowerShell Direct failed: ' + $_.Exception.Message)
  Write-Output 'With a password, pass the credential. With a blank password, check that LimitBlankPasswordUse is 0 inside the guest.'
}

Write-Output '=== Network address ==='
Get-VMNetworkAdapter -VMName $Name | Select-Object Name, SwitchName, IPAddresses | Format-List
