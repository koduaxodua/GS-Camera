# GS Camera

Android-first capture app for Gaussian Splatting reconstruction. Designed to feed clean photo sets into [postshot](https://www.jawset.com/) for interior 3D models used on a real-estate listings website.

## Why this exists

Stock camera apps produce photos that crash postshot or yield blurry, hole-filled splats:
- Auto-exposure drifts → photometric inconsistency between frames
- HDR / Night mode / AI processing → pixel values aren't from one physical scene
- Auto-focus hunts → some frames soft
- Insufficient overlap, missed angles → reconstruction has gaps
- Motion blur → SfM features fail

This app locks the camera, watches the phone's sensors, and only fires the shutter when the frame will be useful. The photographer doesn't need to know what any of that means.

## How to use

1. Open app
2. Pick mode (Room / Object / Spherical) — or just hit the big button for Smart Auto
3. Walk / rotate as the on-screen sphere fills in green
4. Tap Finish when coverage is good
5. Plug phone into PC, drop the session folder into postshot

## Project layout

```
GS-Camera/
├── app/                 # Flutter app (created by `flutter create`)
├── design_notes/        # algorithm design + decision log
├── docs/                # user-facing capture guide + postshot pipeline
└── README.md
```

## Status

See [STATUS.md](STATUS.md) for the live snapshot. Short version:

- [x] Architecture designed
- [x] Flutter SDK installed
- [x] App scaffolded
- [x] Sensor + camera integration (Camera2 with AE/AWB lock + capability adaptation)
- [x] Quality analyzers (blur, lens dirt, lighting)
- [x] Coverage sphere UI
- [x] Export pipeline (folder + session.json + README for postshot)
- [x] Debug + release APK builds
- [ ] Field testing on real interiors
- [ ] iOS port (after April 2026)
