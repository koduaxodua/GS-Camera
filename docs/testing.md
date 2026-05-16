# Testing GS Camera on the phone

Quick reference for the round-trip: build APK → install → test → pull session
folders back to the PC for postshot.

## 1. Install the APK

Latest debug APK lives at:
```
C:\Users\kodua\GS-Camera\app\build\app\outputs\flutter-apk\app-debug.apk
```

If your phone is plugged in via USB with USB debugging on:
```
adb install -r app\build\app\outputs\flutter-apk\app-debug.apk
```

If sideloading via file manager, just open the APK on the phone — Android
will prompt you to allow installs from this source.

## 2. First-launch checklist

1. Tap **Room** (or Object / Spherical).
2. Grant the Camera permission when prompted.
3. The "Calibrating camera…" spinner runs for 1–2 seconds.
4. The capture screen opens with the live preview behind a translucent HUD.

If the preview looks rotated or stretched, **tap the chip at the bottom-left**
(it shows the icon ↻ and the current rotation label, e.g. `Auto`). Each tap
cycles `Auto → 0° → 90° → 180° → 270°`. Whichever value looks right is saved
via `SharedPreferences` and used next time.

## 3. Capturing

- Walk slowly while rotating the phone — the gyroscope decides when to fire.
- The **coverage sphere** at top-right fills in green as bins get covered.
- The **photo counter** at the bottom shows how many shots are saved so far.
- A guidance banner pops up if the device thinks you should slow down, hold
  steadier, or look at a missing area.
- Tap **Finish** at the bottom whenever you're done — it's always enabled,
  the percentage label is just a recommendation.

## 4. Pull the session folder

Sessions land at:
```
/storage/emulated/0/Android/data/com.gscamera.gs_camera/files/GSCamera/Session_YYYY-MM-DD_HHMM/
```

To pull via adb:
```
adb pull /storage/emulated/0/Android/data/com.gscamera.gs_camera/files/GSCamera ./captures
```

Each session folder contains:
- `0001.jpg`, `0002.jpg`, … sequential JPEGs
- `session.json` — sensor metadata per shot (azimuth, elevation, sharpness, ISO)
- `README.txt` — a one-pager telling postshot operators what to do

## 5. Drop into postshot

Open postshot, create a new project from "image sequence", and point it at
the session folder. It should ingest cleanly because:
- Exposure / focus / white balance were locked across every frame
- HDR and computational stacking were disabled
- Frames are all the same resolution and sensor settings
- EXIF preserved (postshot reads focal length etc. for camera intrinsics)

## Troubleshooting

| Symptom | Likely fix |
|---|---|
| Black screen after tapping a mode | Camera permission was denied — check Settings |
| Calibrating spinner never finishes | Old session not closed; force-stop the app and retry |
| Preview rotated wrong | Tap the bottom-left rotation chip until it's upright |
| Preview stretched or letterboxed | Rotation chip — try `0°` or toggle to a different value |
| `Camera failed to start` red error | Read the message; usually means another app holds the camera |
| No photos in DCIM | Captures go to the app's data dir (path above), not DCIM |
| Photos look blurry | Move slower — `Move slower` guidance banner should appear |
| Postshot rejects the session | Open a few JPEGs to confirm exposure consistency; if some look off, delete those frames before retry |
