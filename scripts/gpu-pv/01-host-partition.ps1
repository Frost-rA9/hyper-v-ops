# Assign a GPU partition to the VM. The VM must be off.
#
# Do not raise the partition limits. With VRAM, Encode, Decode, and Compute all
# set to 8 GB, Start-VM fails with 0x800705AA "cannot reserve resources". The
# 80 MB and 100 MB values below work, and they do not limit the memory the guest
# sees. The guest reports the full 12227 MiB either way.
#
# A host can report more than one partitionable GPU: a laptop reports the
# integrated GPU next to the discrete one. Add-VMGpuPartitionAdapter without
# -InstancePath takes the first entry of Get-VMHostPartitionableGpu, which is
# then often the wrong GPU. The guest boots with a partition whose driver files
# are absent and bug checks during start-up. Pass -GpuMatch to name the GPU.
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$GpuMatch,
  [int]$LowMmioMb   = 1024,
  [int]$HighMmioMb  = 32768
)

$ErrorActionPreference = 'Stop'

if ((Get-VM -Name $Name).State -ne 'Off') {
  throw 'The VM must be off. Run Stop-VM first.'
}

$all = @(Get-VMHostPartitionableGpu)
if ($all.Count -eq 0) { throw 'The host reports no partitionable GPU.' }
Write-Output 'Partitionable GPUs:'
$all | Select-Object Name, PartitionCount, ValidPartitionCounts | Format-List

if ($GpuMatch) {
  $match = @($all | Where-Object { $_.Name -like "*$GpuMatch*" })
  if ($match.Count -eq 0) { throw "No partitionable GPU matches '$GpuMatch'." }
  if ($match.Count -gt 1) { throw "'$GpuMatch' matches $($match.Count) partitionable GPUs. Pass a longer selector." }
  $gpu = $match[0]
} elseif ($all.Count -eq 1) {
  $gpu = $all[0]
} else {
  throw "The host reports $($all.Count) partitionable GPUs. Pass -GpuMatch with part of the name, for example -GpuMatch VEN_10DE."
}
Write-Output ('Selected GPU: ' + $gpu.Name)

$adapter = Get-VMGpuPartitionAdapter -VMName $Name -ErrorAction SilentlyContinue
if ($adapter) {
  if ($adapter.InstancePath -eq $gpu.Name) {
    Write-Output 'Adapter exists on the selected GPU. Updating the limits only.'
  } else {
    Write-Output ('Adapter points at another GPU. Replacing it: ' + $adapter.InstancePath)
    Remove-VMGpuPartitionAdapter -VMName $Name
    Add-VMGpuPartitionAdapter -VMName $Name -InstancePath $gpu.Name
    Write-Output 'Adapter added'
  }
} else {
  Add-VMGpuPartitionAdapter -VMName $Name -InstancePath $gpu.Name
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

# PartitionId and CurrentPartitionVRAM stay empty while the VM is off: the host
# assigns the partition at start-up. LowMemoryMappedIoSpace also reads 0 until
# then, even when the value above was set. Check all three after Start-VM.
Get-VMGpuPartitionAdapter -VMName $Name | Format-List InstancePath, PartitionId, CurrentPartitionVRAM, CurrentPartitionEncode
Get-VM -Name $Name | Select-Object GuestControlledCacheTypes, LowMemoryMappedIoSpace, HighMemoryMappedIoSpace | Format-List
