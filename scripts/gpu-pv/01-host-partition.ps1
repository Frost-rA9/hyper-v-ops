# Assign a GPU partition to the VM. The VM must be off.
#
# Do not raise the partition limits. With VRAM, Encode, Decode, and Compute all
# set to 8 GB, Start-VM fails with 0x800705AA "cannot reserve resources". The
# 80 MB and 100 MB values below work, and they do not limit the memory the guest
# sees. The guest reports the full 12227 MiB either way.
param(
  [Parameter(Mandatory)][string]$Name,
  [int]$LowMmioMb   = 1024,
  [int]$HighMmioMb  = 32768
)

$ErrorActionPreference = 'Stop'

if ((Get-VM -Name $Name).State -ne 'Off') {
  throw 'The VM must be off. Run Stop-VM first.'
}

$gpu = Get-VMHostPartitionableGpu
if (-not $gpu) { throw 'The host reports no partitionable GPU.' }
Write-Output 'Partitionable GPU:'
$gpu | Select-Object Name, PartitionCount, ValidPartitionCounts | Format-List

if (Get-VMGpuPartitionAdapter -VMName $Name -ErrorAction SilentlyContinue) {
  Write-Output 'Adapter exists. Updating the limits only.'
} else {
  Add-VMGpuPartitionAdapter -VMName $Name
  Write-Output 'Adapter added'
}

Set-VMGpuPartitionAdapter -VMName $Name `
  -MinPartitionVRAM 80000000 -MaxPartitionVRAM 100000000 -OptimalPartitionVRAM 100000000 `
  -MinPartitionEncode 80000000 -MaxPartitionEncode 100000000 -OptimalPartitionEncode 100000000 `
  -MinPartitionDecode 80000000 -MaxPartitionDecode 100000000 -OptimalPartitionDecode 100000000 `
  -MinPartitionCompute 80000000 -MaxPartitionCompute 100000000 -OptimalPartitionCompute 100000000

# The user-mode part of the display driver needs guest control of the cache
# types. A large BAR also needs enough MMIO space, or the driver fails to load.
Set-VM -Name $Name -GuestControlledCacheTypes $true `
  -LowMemoryMappedIoSpace ($LowMmioMb * 1MB) `
  -HighMemoryMappedIoSpace ($HighMmioMb * 1MB)

Get-VMGpuPartitionAdapter -VMName $Name | Format-List PartitionId, CurrentPartitionVRAM, CurrentPartitionEncode
Get-VM -Name $Name | Select-Object GuestControlledCacheTypes, LowMemoryMappedIoSpace, HighMemoryMappedIoSpace | Format-List
