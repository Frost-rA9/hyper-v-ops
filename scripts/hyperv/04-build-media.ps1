# Rebuild the install media with oscdimg and put the answer file in its root.
#
# A second ISO that holds only the answer file is unreliable. If the original
# media already carries autounattend.xml, the file that wins depends on
# enumeration order. Replacing the original file gives a defined result.
# PromptlessBoot swaps in efisys_noprompt.bin. UEFI then does not wait for a
# keypress, and with the disk-first boot order the first start goes straight
# into the installer.
param(
  [Parameter(Mandatory)][string]$SourceIso,
  [Parameter(Mandatory)][string]$AnswerFile,
  [Parameter(Mandatory)][string]$OutIso,
  [string]$StageDir,
  [string]$OscdimgPath = 'C:\Users\Public\oscdimg.exe',
  [switch]$PromptlessBoot,
  [string]$Label = 'VMEDIA'
)

$ErrorActionPreference = 'Stop'

foreach ($p in @($SourceIso, $AnswerFile, $OscdimgPath)) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing input: $p" }
}
if (-not $StageDir) { $StageDir = Join-Path $env:TEMP 'media-stage' }

if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

$img = Mount-DiskImage -ImagePath $SourceIso -PassThru
$drive = ($img | Get-Volume).DriveLetter
Write-Output "Source media mounted at ${drive}:"

& "$env:SystemRoot\System32\robocopy.exe" "${drive}:\" $StageDir /E /MT:16 /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
$rc = $LASTEXITCODE
Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null
if ($rc -ge 8) { throw "Copy failed with robocopy exit code $rc" }

foreach ($p in @('boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin', 'setup.exe')) {
  if (-not (Test-Path -LiteralPath (Join-Path $StageDir $p))) { throw "Media is incomplete: $p" }
}

# Files copied from a UDF image keep the read-only attribute. Overwriting such a
# file fails until the attribute is cleared.
$stagedAnswer = Join-Path $StageDir 'autounattend.xml'
if (Test-Path -LiteralPath $stagedAnswer) { (Get-Item -LiteralPath $stagedAnswer).IsReadOnly = $false }
$xml = [IO.File]::ReadAllText($AnswerFile, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($stagedAnswer, $xml, (New-Object Text.UTF8Encoding($true)))

$efiImage = if ($PromptlessBoot) { 'efisys_noprompt.bin' } else { 'efisys.bin' }
$bootData = '-bootdata:2#p0,e,b' + (Join-Path $StageDir 'boot\etfsboot.com') +
            '#pEF,e,b' + (Join-Path $StageDir ('efi\microsoft\boot\' + $efiImage))
Write-Output "EFI boot image: $efiImage"

if (Test-Path -LiteralPath $OutIso) { Remove-Item -LiteralPath $OutIso -Force }
& $OscdimgPath -m -o -u2 -udfver102 "-l$Label" $bootData $StageDir $OutIso
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE" }

$out = Get-Item -LiteralPath $OutIso
Write-Output ("Output: " + $out.FullName + "  " + [math]::Round($out.Length/1GB, 2) + ' GB')

$v = Mount-DiskImage -ImagePath $OutIso -PassThru
$vd = ($v | Get-Volume).DriveLetter
try {
  $check = [IO.File]::ReadAllText("${vd}:\autounattend.xml", [Text.Encoding]::UTF8)
  Write-Output ("Answer file written: " + ($check -eq $xml))
} finally {
  Dismount-DiskImage -ImagePath $OutIso -ErrorAction SilentlyContinue | Out-Null
}
