# Take a snapshot.
#
# Hyper-V refuses a checkpoint while a GPU partition adapter is attached. It
# reports that one or more GPUP partitions are assigned to the VM. This script
# detaches the adapter, takes the checkpoint, and attaches the adapter again.
# The driver files live on the guest disk, so a rollback keeps them. Attach the
# adapter again after the rollback to get the GPU back.
# Checkpoint-VM returns before the checkpoint is listed. Poll for it instead of
# reading the list once.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$SnapshotName,
  [int]$WaitSeconds = 120
)

$ErrorActionPreference = 'Continue'

function Wait-Off([string]$vm) {
  for ($i = 0; $i -lt 120; $i++) {
    if ((Get-VM -Name $vm).State -eq 'Off') { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}

Write-Output 'Stopping VM'
Stop-VM -Name $Name -ErrorAction Continue
if (-not (Wait-Off $Name)) {
  Stop-VM -Name $Name -TurnOff -Force
  Wait-Off $Name | Out-Null
}

Write-Output 'Detaching GPU partition adapter'
Remove-VMGpuPartitionAdapter -VMName $Name -ErrorAction Continue

$existing = @(Get-VMSnapshot -VMName $Name -Name $SnapshotName -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
  Write-Output "Checkpoint exists: $SnapshotName"
} else {
  Checkpoint-VM -VMName $Name -SnapshotName $SnapshotName -ErrorAction Continue
  $seen = $false
  for ($i = 0; $i -lt $WaitSeconds; $i++) {
    Start-Sleep -Seconds 2
    $n = @(Get-VMSnapshot -VMName $Name -Name $SnapshotName -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) {
      Write-Output ("Checkpoint visible after " + ($i + 1) * 2 + ' s')
      if ($n -gt 1) { Write-Output "Warning: $n checkpoints share this name. Delete them by object, not by name." }
      $seen = $true
      break
    }
  }
  if (-not $seen) { Write-Output 'Checkpoint did not appear. Check the Hyper-V event log.' }
}

Write-Output 'Attaching GPU partition adapter'
Add-VMGpuPartitionAdapter -VMName $Name -ErrorAction Continue

# Keep these limits. Raising VRAM, Encode, Decode, and Compute to 8 GB makes
# Start-VM fail with 0x800705AA, and the guest sees the full card anyway.
Set-VMGpuPartitionAdapter -VMName $Name -ErrorAction Continue `
  -MinPartitionVRAM 80000000 -MaxPartitionVRAM 100000000 -OptimalPartitionVRAM 100000000 `
  -MinPartitionEncode 80000000 -MaxPartitionEncode 100000000 -OptimalPartitionEncode 100000000 `
  -MinPartitionDecode 80000000 -MaxPartitionDecode 100000000 -OptimalPartitionDecode 100000000 `
  -MinPartitionCompute 80000000 -MaxPartitionCompute 100000000 -OptimalPartitionCompute 100000000

Start-VM -Name $Name -ErrorAction Continue

Get-VMSnapshot -VMName $Name | Select-Object Name, CreationTime | Sort-Object CreationTime | Format-Table
Get-VMGpuPartitionAdapter -VMName $Name | Format-List PartitionId, CurrentPartitionVRAM, CurrentPartitionEncode
