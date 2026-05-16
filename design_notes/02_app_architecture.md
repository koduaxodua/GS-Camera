# GS Camera — App Architecture

## Layers

```
┌────────────────────────────────────────────────────────────┐
│  UI (Flutter widgets)                                      │
│   - HomeScreen, CaptureScreen, ReviewScreen                │
│   - CoverageSphereWidget, GuidanceOverlay, BubbleLevel     │
└────────────────┬───────────────────────────────────────────┘
                 │ ValueListenable / Stream
┌────────────────┴───────────────────────────────────────────┐
│  CaptureCoordinator (the brain)                            │
│   - decides when to fire shutter                           │
│   - decides when to surface guidance                       │
│   - tracks session state                                   │
└─────┬────────────────────────────────────┬─────────────────┘
      │                                    │
┌─────┴──────────┐              ┌──────────┴─────────────────┐
│ SensorManager  │              │  CameraService             │
│  (Dart only)   │              │   (Dart facade over native)│
│  - gyro/accel  │              │  - manual AE/AF/AWB lock   │
│  - rotation    │              │  - capture preview frames  │
│    fusion      │              │  - capture full-res JPEG   │
└────────────────┘              └─────┬──────────────────────┘
                                      │ MethodChannel
                                ┌─────┴──────────────────────┐
                                │  Native Android plugin     │
                                │  (Kotlin + Camera2)        │
                                │  - lock-everything mode    │
                                │  - on-frame Laplacian      │
                                └────────────────────────────┘

Quality analyzers run on preview frames as they arrive:
┌────────────────────────────────────────────────────────────┐
│  QualityAnalyzers                                          │
│   - BlurDetector       (Laplacian variance)                │
│   - LensDirtDetector   (smudge spotting; pre-flight only)  │
│   - LightingAnalyzer   (histogram + clipping)              │
└────────────────────────────────────────────────────────────┘

Coverage tracking:
┌────────────────────────────────────────────────────────────┐
│  CoverageMap (icosphere bins, ~500 cells)                  │
│   - on each accepted shot, increment bin at current azim/elev│
│   - exposed to UI as a 3D mesh + completion %              │
└────────────────────────────────────────────────────────────┘
```

## Key decision: Dart vs. native split

**Dart side handles:**
- All UI
- Sensor reading (`sensors_plus` package is fine, ~50 Hz updates)
- Coverage map math
- Capture coordinator state machine
- Quality scoring on small preview frames (Laplacian on 320×240 is fast in Dart, ~5 ms)

**Native (Kotlin / Camera2) side handles:**
- Manual exposure / focus / WB lock — `flutter camera` package can't do this reliably
- Per-frame YUV preview callback (so we can do blur scoring without copying every frame to Dart)
- Full-resolution JPEG capture with EXIF write
- Disabling computational photography (HDR off, scene mode off, edge/noise low)

Why the split: Flutter's `camera` package does 90% of what we need but explicitly does not expose AE/AF/AWB lock toggles, and that's the most important feature for postshot. So we write a thin native plugin for camera control while keeping all logic in Dart.

For iOS port later: same Dart code, swap the native plugin for AVFoundation (Swift). Coordinator + UI stay identical.

## Folder layout (after `flutter create app`)

```
app/
├── android/
│   └── app/src/main/kotlin/.../GsCameraPlugin.kt      # native Camera2
├── ios/                                                # placeholder, fill later
├── lib/
│   ├── main.dart
│   ├── core/
│   │   ├── capture_coordinator.dart
│   │   ├── sensor_manager.dart
│   │   ├── coverage_map.dart
│   │   └── session.dart
│   ├── services/
│   │   ├── camera_service.dart                         # platform channel facade
│   │   ├── blur_detector.dart
│   │   ├── lens_dirt_detector.dart
│   │   ├── lighting_analyzer.dart
│   │   └── exporter.dart                               # writes JPEGs + sidecar
│   ├── ui/
│   │   ├── home_screen.dart
│   │   ├── capture_screen.dart
│   │   ├── review_screen.dart
│   │   └── widgets/
│   │       ├── coverage_sphere.dart
│   │       ├── guidance_overlay.dart
│   │       └── bubble_level.dart
│   └── models/
│       ├── photo_meta.dart
│       └── capture_mode.dart
├── pubspec.yaml
└── test/
```

## State machine (CaptureCoordinator)

```
   ┌────────┐  start  ┌──────────────┐  pre-flight ok  ┌─────────┐
   │  idle  ├────────►│  pre-flight  ├────────────────►│ locking │
   └────────┘         └──────┬───────┘                 └────┬────┘
                             │ pre-flight failed            │ AE/AF/AWB locked
                             ▼                              ▼
                     ┌──────────────┐               ┌────────────┐
                     │ guidance     │               │  capturing │◄──┐
                     │ (wipe lens / │               └─────┬──────┘   │
                     │  add light)  │                     │ shot     │
                     └──────┬───────┘                     │  fired   │
                            │ user fixed                  │          │
                            └────────────┐                ▼          │
                                         ▼          ┌────────────┐   │
                                  back to pre-flight│ updating   │   │
                                                    │ coverage + │───┘
                                                    │ scoring    │
                                                    └─────┬──────┘
                                                          │ user taps Finish
                                                          ▼
                                                    ┌────────────┐
                                                    │  exporting │
                                                    └─────┬──────┘
                                                          ▼
                                                    ┌────────────┐
                                                    │  review    │
                                                    └────────────┘
```

## Dependencies (pubspec.yaml — to add)

```yaml
dependencies:
  flutter:
    sdk: flutter
  camera: ^0.11.0           # base camera; we extend via native plugin
  sensors_plus: ^6.0.0      # gyro / accel / magneto
  permission_handler: ^11.0.0
  path_provider: ^2.1.0
  exif: ^3.3.0              # read/write EXIF on captured JPEGs
  vector_math: ^2.1.4       # quaternion math for sensor fusion + sphere
  image: ^4.2.0             # Laplacian / histogram on Dart side
  share_plus: ^10.0.0       # share session folder out
  wakelock_plus: ^1.2.5     # don't dim screen during capture
  shared_preferences: ^2.3.0

dev_dependencies:
  flutter_lints: ^4.0.0
  flutter_test:
    sdk: flutter
```

## Performance budget per preview frame (target 30 fps preview)

- Sensor read: < 1 ms (background isolate)
- Blur score on 320×240: ~5-8 ms
- Coverage bin update: < 1 ms
- UI rebuild: ~5 ms
- **Headroom:** ~15 ms — plenty for the trigger evaluation logic

The full-res JPEG capture happens off the preview pipeline so it doesn't drop frames.
