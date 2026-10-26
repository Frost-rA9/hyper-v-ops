# Create the Generation 2 virtual machine.
#
# Static memory: a GPU partition needs fixed memory. Dynamic memory makes the
# address mapping of the partition adapter unstable.
# Boot order: hard disk first, DVD second. Use this order together with install
# media that has no key prompt. On the first start the disk is empty, so the
# firmware falls through to the DVD. After the install the disk holds the boot
# loader, so a restart comes back to the disk.
# Reversed order plus the prompt image makes the guest wait for a keypress on a
# screen that nobody can see.
param(
  [Parameter(Mandatory)][string]$Name,
  [int]$ProcessorCount        = 4,
  [int]$MemoryGB              = 16,
  [Parameter(Mandatory)][string]$VhdPath,
  [int]$VhdSizeGB             = 150,
  [string]$SwitchName         = 'HvSwitch',
  [string]$IsoPath,
  [switch]$NoTpm
)

$ErrorActionPreference = 'Stop'

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "VM already exists: $Name" }
if ($IsoPath -and -not (Test-Path -LiteralPath $IsoPath)) { throw "Install media not found: $IsoPath" }
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) { throw "Switch not found: $SwitchName" }

$dir = Split-Path -Parent $VhdPath
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
       -NewVHDPath $VhdPath -NewVHDSizeBytes ($VhdSizeGB * 1GB) `
       -SwitchName $SwitchName | Out-Null

Set-VM -Name $Name -ProcessorCount $ProcessorCount -StaticMemory `
       -AutomaticCheckpointsEnabled $false `
       -AutomaticStartAction Nothing -AutomaticStopAction ShutDown | Out-Null

Set-VMFirmware -VMName $Name -EnableSecureBoot On | Out-Null

if (-not $NoTpm) {
  Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
  Enable-VMTPM -VMName $Name
}

if ($IsoPath) {
  Add-VMDvdDrive -VMName $Name -Path $IsoPath | Out-Null
  $dvd = Get-VMDvdDrive -VMName $Name
  $hdd = Get-VMHardDiskDrive -VMName $Name
  Set-VMFirmware -VMName $Name -BootOrder $hdd, $dvd | Out-Null
}

Get-VM -Name $Name | Select-Object Name, State, ProcessorCount,
  @{n='MemGB';e={[int]($_.MemoryStartup/1GB)}}, DynamicMemoryEnabled | Format-List
Get-VMFirmware -VMName $Name | Select-Object SecureBoot, SecureBootTemplate | Format-List
Get-VMHardDiskDrive -VMName $Name | Select-Object Path, ControllerLocation | Format-Table
