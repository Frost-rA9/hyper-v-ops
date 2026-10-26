# Create the internal switch, the host address, and the NAT rule.
#
# This script uses an internal switch instead of the default switch. The default
# switch changes its subnet after a host restart, and both the Sunshine pairing
# and the Moonlight host entry store the IP address. The NAT rule only gives the
# guest internet access. Stream traffic does not pass through it.
param(
  [string]$SwitchName = 'HvSwitch',
  [string]$HostIp     = '192.168.100.1',
  [int]$PrefixLength  = 24,
  [string]$NatName    = 'HvNat'
)

$ErrorActionPreference = 'Stop'
$alias = "vEthernet ($SwitchName)"

if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
  Write-Output "Switch exists: $SwitchName"
} else {
  New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
  Write-Output "Switch created: $SwitchName"
}

# The host adapter appears a moment after the switch exists.
for ($i = 0; $i -lt 20; $i++) {
  if (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) { break }
  Start-Sleep -Milliseconds 250
}

$existing = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $HostIp }
if ($existing) {
  Write-Output "Host address already set: $HostIp"
} else {
  New-NetIPAddress -InterfaceAlias $alias -IPAddress $HostIp -PrefixLength $PrefixLength | Out-Null
  Write-Output "Host address set: $HostIp/$PrefixLength"
}

$prefix = ($HostIp -replace '\.\d+$', '.0') + "/$PrefixLength"
if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
  Write-Output "NAT exists: $NatName"
} else {
  New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $prefix | Out-Null
  Write-Output "NAT created: $NatName -> $prefix"
}

Get-VMSwitch -Name $SwitchName | Select-Object Name, SwitchType | Format-List
Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength, AddressState | Format-Table
Get-NetNat -Name $NatName | Select-Object Name, InternalIPInterfaceAddressPrefix, Active | Format-Table
