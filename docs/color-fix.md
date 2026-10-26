# FP16 capture colour fault

## Conclusion

Sunshine `2026.914.233613` captures an SDR desktop as FP16. It then applies the sRGB curve a second time to pixels that already carry sRGB gamma encoding. The result is a brighter image.

The fix is in `2026.1018.5342` and requires the option `fp16_sdr_gamma_encoded`. With the fix, the measured gamma moved from 0.466 to 1.000, and all 16 grey steps match the input.

## Symptoms

The image looks pale, highlights blow out, and colours look oversaturated. Two measurements describe the fault:

- Grey levels are lifted. Mid-tones look lighter than the input.
- Pure colours clip near 255. The level structure is lost.

## Trigger conditions

Three conditions apply together:

1. Windows classifies the display as HDR capable or 10-bit capable. A VDD virtual display qualifies because its EDID declares HDR static metadata.
2. Windows therefore composites the desktop as `DXGI_FORMAT_R16G16B16A16_FLOAT` (FP16).
3. The client requests an 8-bit SDR session.

The encoder makes no difference. H.264, HEVC, and AV1 use the same conversion path.

## Measurements

Method: set the calibration image (`reference/calib-reference.png`) as the guest wallpaper. Take a PNG screenshot of the Moonlight window on the host. Run `scripts/tools/analyze-shot.ps1` on the screenshot.

### Build A: 2026.914.233613

| Input | 17 | 34 | 51 | 68 | 85 | 102 | 119 | 136 | 153 | 170 | 187 | 204 | 221 | 238 | 255 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Measured | 72 | 101 | 123 | 140 | 156 | 169 | 182 | 193 | 204 | 213 | 223 | 231 | 240 | 247 | 255 |
| Error | +55 | +67 | +72 | +72 | +71 | +67 | +63 | +57 | +51 | +43 | +36 | +27 | +19 | +9 | 0 |

Fit: `output = 255 * (input/255)^0.466`.

Check the fit with input 17. Treat 0.0667 as a linear value and encode it once more: `1.055 x 0.0667^(1/2.4) - 0.055 = 0.2865`, which is 73. The measurement is 72.

| Expected | Measured | Error |
|---|---|---|
| 128,128,128 | 188,188,188 | +60 |
| 64,64,64 | 137,137,137 | +73 |
| 255,0,0 | 254,0,0 | -1 |
| 0,255,0 | 0,255,1 | +1 |
| 0,0,255 | 0,0,254 | -1 |

The error of the pure colours stays within 1. The Rec.601 and Rec.709 matrices therefore agree. The error comes from the transfer curve only.

### Build B: 2026.1018.5342 with `fp16_sdr_gamma_encoded`

| Input | 17 | 34 | 51 | 68 | 85 | 102 | 119 | 136 | 153 | 170 | 187 | 204 | 221 | 238 | 255 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Measured | 17 | 34 | 51 | 68 | 85 | 102 | 119 | 136 | 153 | 170 | 187 | 204 | 221 | 238 | 255 |

Fit: `output = 255 * (input/255)^1`. The patch `128,128,128` measures 128, and `64,64,64` measures 64.

## Root cause

1. The session log reports `Desktop format [DXGI_FORMAT_R16G16B16A16_FLOAT]` together with `Color coding: SDR (Rec. 601)` and `Color depth: 8-bit`.
2. The grey error matches one extra sRGB encode. The colour patches stay within 1. This rules out a matrix fault and a range fault.
3. Strings inside `sunshine.exe` in the guest contain neither `fp16_sdr_gamma_encoded` nor the matching log text. The option exists on the master branch only.
4. Upstream PR #5106 merged into master on 2026-10-09. Release `2026.914.233613` was published on 2026-09-15 and does not contain the fix. Prerelease `2026.1018.5342` was published on 2026-10-18 and does.

Note: `docs/configuration.md` documents the master branch. Check whether an option exists in your build against the binary strings or the startup log, not against the published docs.

After the fix, the session log contains this line:

```
Info: Treating FP16 SDR capture as gamma-encoded (fp16_sdr_gamma_encoded)
```

## Configuration

```
fp16_sdr_gamma_encoded = enabled
```

Warning: If the capture is linear scRGB, this option darkens the image. Check `Desktop format` in the log and the image itself. Enable the option only when the format is FP16 and the image is pale.

## Acceptance test

1. Set the guest wallpaper to `reference/calib-reference.png`. The image is 2560x1440, so fill mode maps it one to one.
2. Connect with Moonlight in fullscreen or windowed mode.
3. Take a screenshot of the Moonlight window and save it as PNG. JPEG chroma compression makes the measurement invalid.
4. Run `scripts/tools/analyze-shot.ps1 -Path <screenshot>` and read the gamma fit and the per-cell error.

Pass criteria: gamma between 0.99 and 1.01, and an error of at most 2 per cell.

## Rollback

Build `2026.914.233613` brings the fault back:

```
https://github.com/LizardByte/Sunshine/releases/download/v2026.914.233613/Sunshine-Windows-AMD64-installer.msi
```

## References

- Fix: https://github.com/LizardByte/Sunshine/pull/5106
- Build with the fix: `v2026.1018.5342`
- The PR author reported the same fault on Windows 11. The test machine used an RTX 5090, a VDD virtual display, and an HEVC NVENC 8-bit SDR session.
