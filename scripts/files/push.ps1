# Copy host files into the guest.
#
# The guest needs no file share and no firewall rule. The files travel on a
# scratch VHDX: the host mounts it, writes the payload, detaches it, and attaches
# it to the VM. PowerShell Direct then copies the payload inside the guest.
# For a single file the script compares SHA256 on both sides. For a directory it
# reports the file count and the total size.
param(
  [Parameter(Mandatory)][string]$VMName,
  [Parameter(Mandatory)][string]$SourcePath,
  [Parameter(Mandatory)][string]$DestDir,
  [Parameter(Mandatory)][string]$VhdPath,
  [Parameter(Mandatory)][string]$User,
  [int]$VhdSizeGB = 8,
  [int]$ControllerLocation = 2
)

$ErrorActionPreference = 'Stop'
$cred = New-Object System.Management.Automation.PSCredential($User, (New-Object System.Security.SecureString))

if (-not (Test-Path -LiteralPath $SourcePath)) { throw "Source not found: $SourcePath" }
$isDir = (Get-Item -LiteralPath $SourcePath).PSIsContainer
$leaf = Split-Path -Leaf $SourcePath

if (-not (Test-Path -LiteralPath $VhdPath)) {
  $dir = Split-Path -Parent $VhdPath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  New-VHD -Path $VhdPath -SizeBytes ($VhdSizeGB * 1GB) -Dynamic | Out-Null
  $d = Mount-VHD -Path $VhdPath -Passthru
  Start-Sleep -Seconds 2
  $d = $d | Get-Disk
  Initialize-Disk -Number $d.Number -PartitionStyle GPT | Out-Null
  $part = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter
  Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'TRANSFER' -Confirm:$false | Out-Null
  Dismount-VHD -Path $VhdPath
  Write-Output "Scratch disk created: $VhdPath ($VhdSizeGB GB)"
}

$attached = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $VhdPath }
if ($attached) {
  $ControllerLocation = $attached.ControllerLocation
  Remove-VMHardDiskDrive $attached
  Start-Sleep -Seconds 2
}

Mount-VHD -Path $VhdPath | Out-Null
Start-Sleep -Seconds 2
$disk = Get-Disk | Where-Object { $_.FriendlyName -like '*Virtual*' } | Sort-Object Number -Descending | Select-Object -First 1
$part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.DriveLetter } | Select-Object -First 1
$drive = $part.DriveLetter
$inbox = "${drive}:\inbox"
New-Item -ItemType Directory -Path $inbox -Force | Out-Null

if ($isDir) {
  & robocopy.exe $SourcePath (Join-Path $inbox $leaf) /E /MT:16 /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
} else {
  Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $inbox $leaf) -Force
}
$hostHash = $null
if (-not $isDir) {
  $hostHash = (certutil -hashfile (Join-Path $inbox $leaf) SHA256 | Select-Object -Index 1).Trim()
}
Dismount-VHD -Path $VhdPath
Start-Sleep -Seconds 2

Add-VMHardDiskDrive -VMName $VMName -ControllerNumber 0 -ControllerLocation $ControllerLocation -Path $VhdPath
Start-Sleep -Seconds 8

$result = Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ScriptBlock {
  param($leaf, $DestDir, $isDir, $hostHash)
  $letter = (Get-Volume | Where-Object { $_.FileSystemLabel -eq 'TRANSFER' } | Select-Object -First 1).DriveLetter
  if (-not $letter) { return 'The guest does not see the scratch disk' }
  $src = "${letter}:\inbox\$leaf"
  if (-not (Test-Path -LiteralPath $src)) { return "The scratch disk has no $leaf" }
  if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }

  if ($isDir) {
    & robocopy.exe $src $DestDir /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    $files = Get-ChildItem -LiteralPath $DestDir -Recurse -File
    return ("Directory copied: {0} files, {1} MB" -f $files.Count, [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1))
  }

  $dst = Join-Path $DestDir $leaf
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $guestHash = (certutil -hashfile $dst SHA256 | Select-Object -Index 1).Trim()
  return ("File copied: {0}, {1} bytes, SHA256 matches={2}" -f $dst, (Get-Item $dst).Length, ($guestHash -eq $hostHash))
} -ArgumentList $leaf, $DestDir, $isDir, $hostHash

Write-Output $result
Write-Output 'The scratch disk stays attached. To remove it:'
Write-Output ("  Remove-VMHardDiskDrive (Get-VMHardDiskDrive -VMName $VMName | Where-Object { `$_.Path -eq '$VhdPath' })")
