# Measure colour error from a screenshot.
#
# The input is a PNG screenshot of the Moonlight window. The content is
# reference/calib-reference.png: 16 grey steps on the top half and 8 colour
# patches on the bottom half.
# Sample points use ratios: grey at 25% of the content height, patches at 75%.
# The grey row is sampled at 25% and not at 55% because the red labels sit above
# each grey cell, and label pixels spoil the sample.
# Do not use a JPEG screenshot. Chroma compression makes the samples unreliable.
param(
  [Parameter(Mandatory)][string]$Path
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing

$bmp = [System.Drawing.Bitmap]::FromFile($Path)
$W = $bmp.Width; $H = $bmp.Height
Write-Output ("Image: {0}x{1}" -f $W, $H)

$contentH = [int]($W * 1440 / 2560)
if ($contentH -gt $H) { $contentH = $H }
Write-Output ("Content area assumed: {0}x{1}" -f $W, $contentH)

function Sample([int]$cx, [int]$cy, [int]$r = 8) {
  $sr = 0; $sg = 0; $sb = 0; $n = 0
  for ($y = [Math]::Max(0, $cy - $r); $y -le [Math]::Min($H - 1, $cy + $r); $y++) {
    for ($x = [Math]::Max(0, $cx - $r); $x -le [Math]::Min($W - 1, $cx + $r); $x++) {
      $c = $bmp.GetPixel($x, $y); $sr += $c.R; $sg += $c.G; $sb += $c.B; $n++
    }
  }
  [pscustomobject]@{ R = [int][math]::Round($sr / $n); G = [int][math]::Round($sg / $n); B = [int][math]::Round($sb / $n) }
}

$rampY = [int]($contentH * 0.25)
$cellW = $W / 16
Write-Output ''
Write-Output ("=== Grey steps (y=$rampY) ===")
$ramp = @()
for ($i = 0; $i -lt 16; $i++) {
  $s = Sample ([int](($i + 0.5) * $cellW)) $rampY
  $exp = [int][math]::Round(255 * $i / 15)
  $ramp += [pscustomobject]@{ Exp = $exp; Act = $s.R }
  Write-Output ("{0,4}  expected {1,3}  measured {2,3},{3,3},{4,3}  error {5,4}" -f $i, $exp, $s.R, $s.G, $s.B, ($s.R - $exp))
}

$pts = $ramp | Where-Object { $_.Exp -gt 8 -and $_.Exp -lt 250 -and $_.Act -gt 0 -and $_.Act -lt 255 }
if ($pts.Count -ge 3) {
  $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0; $n = $pts.Count
  foreach ($p in $pts) {
    $lx = [math]::Log($p.Exp / 255.0); $ly = [math]::Log($p.Act / 255.0)
    $sx += $lx; $sy += $ly; $sxx += $lx * $lx; $sxy += $lx * $ly
  }
  $g = ($n * $sxy - $sx * $sy) / ($n * $sxx - $sx * $sx)
  Write-Output ''
  Write-Output ("Fit: output = 255 * (input/255)^{0}" -f [math]::Round($g, 3))
  if ($g -lt 0.95) { Write-Output 'Result: the image is too bright. Check the Sunshine build and fp16_sdr_gamma_encoded.' }
  elseif ($g -gt 1.05) { Write-Output 'Result: the image is too dark. Check whether fp16_sdr_gamma_encoded is enabled on a linear scRGB capture.' }
  else { Write-Output 'Result: the transfer curve is correct.' }
}

$patchY = [int]($contentH * 0.75)
$pw = $W / 8
$exp = @(@(255,0,0),@(0,255,0),@(0,0,255),@(255,255,0),@(0,255,255),@(255,0,255),@(128,128,128),@(64,64,64))
Write-Output ''
Write-Output ("=== Colour patches (y=$patchY) ===")
for ($i = 0; $i -lt 8; $i++) {
  $s = Sample ([int](($i + 0.5) * $pw)) $patchY 10
  $e = $exp[$i]
  Write-Output ("{0}  expected {1,3},{2,3},{3,3}  measured {4,3},{5,3},{6,3}  error {7,4},{8,4},{9,4}" -f `
    $i, $e[0], $e[1], $e[2], $s.R, $s.G, $s.B, ($s.R - $e[0]), ($s.G - $e[1]), ($s.B - $e[2]))
}

$bmp.Dispose()
