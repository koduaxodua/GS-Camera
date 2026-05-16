# GS Camera — Smart Capture Algorithm

End goal: produce a folder of JPEGs that postshot can train a Gaussian Splatting model on without crashing or producing artifacts. Optimized for interior rooms used in a real-estate listings website.

---

## Why stock cameras fail for GS

- Auto-exposure drifts between frames → photometric inconsistency
- Auto-focus hunts → some frames soft
- HDR / Night mode / AI processing → pixel values are not from a single physical scene
- Insufficient overlap → reconstruction has holes
- Motion blur → SfM features fail
- Mixed lighting / dirty lens → low-quality features

This app exists because every one of those problems must be solved before postshot ever sees the data.

---

## Pipeline

```
[ pre-flight checks ] -> [ lock camera params ] -> [ capture loop ] -> [ review + export ]
       1-3 s                    instant                main work          quick
```

### 1. Pre-flight checks (silent if all pass)

Run on first 1-2 seconds of preview frames before letting user start.

| Check | Method | If fails |
|---|---|---|
| Lens dirty / smudged | Local-contrast variance map; smudges show as low-contrast circular blobs in otherwise sharp scene; also blue-channel haze | Full-screen "📷 Wipe your camera lens" + Done button |
| Lighting too dark | Mean luminance < 60 (8-bit), need to raise ISO above safe limit | "Add light" with suggestion to open curtains / turn on lamps |
| Lighting clipped | > 5% of pixels at 255 | "Avoid pointing at direct light source" |
| Mixed color temps | High variance in WB estimate per region | Soft warning, not a block |
| Storage | < 2 GB free | Block with message |
| Battery | < 20% and not charging | Warn, allow continue |

### 2. Lock camera params (Camera2 manual mode)

Once user enters capture, do AE/AF/AWB sweep then lock:

- **Exposure:** spot-meter the center, run ~10 frames of AE, then `CONTROL_AE_LOCK = true`
- **Focus:** auto-focus on center, then `LENS_FOCUS_DISTANCE` to that value
- **WB:** auto-WB for ~10 frames, then `CONTROL_AWB_LOCK = true`
- **Scene mode:** `CONTROL_SCENE_MODE_DISABLED`
- **HDR:** disabled
- **Edge / noise reduction:** set to `OFF` or `FAST` (avoid aggressive)
- **Shutter speed floor:** 1/120s minimum to prevent motion blur; ISO ceiling derived from that
- **Output:** highest-resolution JPEG, `JPEG_QUALITY = 95`

This is "good enough for the whole session" — postshot wants identical look across all frames, even if exposure isn't perfect for any individual frame.

### 3. Capture loop

Sensors update at 50-100 Hz. Every frame, evaluate trigger:

```
fire_capture := (
    angular_displacement_since_last_shot >= θ_mode
    AND angular_velocity < ω_max
    AND linear_acceleration < a_max
    AND preview_blur_score > S_min
    AND not_returning_to_covered_area
)
```

`θ_mode` per mode:
- Room Walkthrough: 6° rotation OR 30 cm translation
- Object Orbit: 5° rotation around target
- Spherical: 7° rotation

Rejected captures are silent — no shutter sound, no UI flash. Only the heads-up sphere fills in.

### 4. Real-time guidance (only when needed)

Stays out of user's way. Triggers only if a problem persists for ~2-3 sec:

| Symptom | Hint |
|---|---|
| 3 consecutive blur-rejected frames | "🐢 Move slower" |
| No shots fired in 5 s + sensors active | "↻ Continue moving" |
| Big shake on accel | "🤚 Hold steadier" |
| Phone tilted >30° from intended axis | Bubble level overlay |
| Coverage map shows persistent gap behind user | Arrow: "Look behind you" |
| Returning to same azimuth bin >3× | "✓ Already covered, try a new spot" |

Tutorial ("Onboarding"): first launch only. ~30 sec animated overlay showing the room walkthrough motion. Skippable. Replayable from settings.

### 5. Coverage map

Sphere divided into ~500 bins (icosphere subdivision, level 4). Each bin tracks:
- shot count
- average sharpness
- timestamp of last shot

Rendered as a rotating mini-globe in HUD corner. Bins colored:
- gray = no coverage
- yellow = 1-2 shots
- green = ≥3 shots
- red flash = quality issue

Capture session is "complete" when ≥70% of expected bins are green (per mode).

For Room mode the "expected" set excludes the floor directly under the user and the small cone directly above (those typically aren't useful).

### 6. Export

On Finish:
1. Folder: `DCIM/GSCamera/Session_YYYY-MM-DD_HHMM/`
2. Files: `0001.jpg`, `0002.jpg`, ... sequential, EXIF preserved
3. Sidecar: `session.json` with sensor metadata (azimuth/elevation/roll per frame, sharpness, ISO/shutter)
4. README: a one-pager telling the user how to drop the folder into postshot

---

## Quality scoring (on-device, fast)

- **Blur:** Laplacian-of-Gaussian variance on a downscaled grayscale (320×240) — runs in ~5-10 ms. Threshold tuned per ISO (more noise → higher threshold).
- **Exposure:** mean + percentiles on luminance histogram (8-bit, 64 bins).
- **Lens dirt:** Sobel magnitude in smooth regions; smudges show as pixels with low gradient *and* low high-frequency content. Run only during pre-flight (heavy).

---

## Sensor choices

- **TYPE_GAME_ROTATION_VECTOR** (Android) — fused gyro+accel without magnetometer drift; great for relative motion since session start.
- **TYPE_ACCELEROMETER** — for shake detection and rough translation estimate.
- **TYPE_MAGNETIC_FIELD** — only used for absolute heading on Spherical mode (where heading drift would matter less than session-relative angles).

Magnetic compass intentionally NOT used for auto-trigger — magnetometer gets corrupted indoors near appliances/wiring.

---

## What we explicitly do NOT do

- Auto-stitch panoramas (postshot wants raw images)
- Apply any color/tone curves (must stay raw photometric values)
- Compress beyond JPEG 95 (postshot is sensitive to compression artifacts)
- Use front camera (FoV is wrong for GS)
- Capture during walking-while-rotating combo (too much motion blur risk)

---

## Mode reference card

| Mode | Use case | Trigger | Total shots target |
|---|---|---|---|
| Room Walkthrough | Whole apartment | 6° rotation OR 30 cm translation | 150-300 |
| Object Orbit | Single piece of furniture | 5° rotation around fixed target | 60-90 |
| Spherical | "Stand here, scan around" | 7° rotation | 40-60 |
