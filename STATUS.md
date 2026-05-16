# GS Camera — Current State

Snapshot of where the project stands. Updated as features land.

## ✅ Working

- Flutter SDK 3.41.7 installed at `C:\Users\kodua\dev\flutter`
- Android SDK + NDK + cmdline-tools installed, all licenses accepted
- App scaffold at `app/`, package `com.gscamera.gs_camera`, minSdk 26
- Permission handling: requests camera at session start, surfaces a snackbar if denied
- Three capture modes (Room / Object / Spherical) with their own trigger thresholds
- Native Camera2 plugin (`android/app/src/main/kotlin/com/gscamera/gs_camera/CameraSession.kt`):
  - Adapts to device hardware level — uses `LENS_FOCUS_DISTANCE` only on phones
    with `MANUAL_SENSOR` capability, falls back to AF-trigger-cancel on the rest
  - Locks AE / AWB after a short convergence sweep (4 s timeout safety net)
  - Disables HDR, scene mode, video stabilization, computational photography
  - Streams 320×240 YUV preview frames to Dart for blur / lighting / lens-dirt analysis
  - Saves full-resolution JPEGs at quality 95 with EXIF
- Camera preview rendering via Flutter `Texture` widget bound to a Camera2 SurfaceTexture
- HUD: coverage sphere (top-right), bubble level (top-left), photo counter + Finish button (bottom)
- Manual rotation override chip at bottom-left if auto-rotation guesses wrong
- Capture coordinator firing the shutter on rotation triggers + sensor stillness
- Export pipeline writing `Session_YYYY-MM-DD_HHMM/` folders with sequential JPEGs +
  `session.json` + a `README.txt` for postshot operators
- Debug + release APKs build cleanly

## 🚧 Known issues / open items

- The auto-rotation pathway assumes Flutter's Texture widget applies the
  SurfaceTexture transform automatically. On some devices this may need the
  manual override (the bottom-left chip) — confirmed this on first install.
  Once the right value is found the chip persists it via SharedPreferences.
- Device locked to portrait. Landscape support requires reading device
  orientation and recomputing rotation continuously — deferred.
- Coverage sphere currently uses a 2D polar projection, not a real sphere
  mesh. Good enough for guidance; can revisit if the user wants prettier.
- Translation tracking from accelerometer drifts heavily. We use it only as a
  "did the user walk a step" hint, not for true SfM. postshot does the real
  pose recovery.
- Lens-dirt detector is heuristic (Sobel + tile-mean variance). Tuning may
  be needed against real smudge samples once we field-test.
- No iOS implementation yet — deferred until next month per the plan.

## 📋 Suggested next step after the user returns

1. Confirm the preview is correct in Room mode. If wrong:
   - Tap the rotation chip (bottom-left) until the camera looks upright
   - The setting will persist
2. Walk through a real room while the coverage sphere fills in
3. Hit Finish once the bottom button enables ("≥ 70% needed" disappears)
4. Pull the session folder off the phone — it lands at:
   `Internal storage / Android / data / com.gscamera.gs_camera / files / GSCamera / Session_*`
5. Drop the folder into postshot as an image sequence

## 📂 Build artefacts

| Build | Path | Size |
|---|---|---|
| Debug APK | `app/build/app/outputs/flutter-apk/app-debug.apk` | 175 MB |
| Release APK | `app/build/app/outputs/flutter-apk/app-release.apk` | 45 MB |

Both signed with the debug key — fine for personal sideloading, not for
Play Store. A real signing config should be added before any public
distribution. The release APK was built with `--no-shrink` because Gradle
kept timing out pulling R8 artifacts on the slow connection; with R8 it
would compress further to ~30 MB, but `--no-shrink` is a fine workaround.

## 🛠 Helper scripts

- `scripts/install_and_run.bat` — installs the debug APK on a USB-connected
  phone, launches it, and tails logcat with our app's tags. Use this any
  time we need to see why something crashed.
- `scripts/pull_sessions.bat` — pulls every saved session folder off the
  phone into `./captures/` so you can drop them into postshot.

Both expect adb at `C:\Users\kodua\AppData\Local\Android\Sdk\platform-tools`
and the phone in USB-debugging mode.
