# How to merge this template into the Flutter project

After `flutter create app --org com.gscamera --project-name gs_camera` runs,
do these steps to wire the smart-capture code into the generated scaffold.

## 1. Replace `app/lib/`

Delete the auto-generated `app/lib/main.dart` and copy everything from
`_template/lib/` into `app/lib/`:

```
_template/lib/main.dart            -> app/lib/main.dart
_template/lib/core/                -> app/lib/core/
_template/lib/services/            -> app/lib/services/
_template/lib/models/              -> app/lib/models/
_template/lib/ui/                  -> app/lib/ui/
```

## 2. Replace `pubspec.yaml`

Copy `_template/pubspec.yaml` over `app/pubspec.yaml` (preserving the
`name:` line if `flutter create` chose a different one — the dependencies
section is what matters). Then:

```
cd app
flutter pub get
```

## 3. Wire the native plugin

Copy:
```
_template/android_native/GsCameraPlugin.kt   -> app/android/app/src/main/kotlin/com/gscamera/
_template/android_native/CameraSession.kt    -> app/android/app/src/main/kotlin/com/gscamera/
_template/android_native/MainActivity.kt     -> app/android/app/src/main/kotlin/com/gscamera/   (overwrite)
```

If `flutter create` used a different package directory (e.g. `com/example/app`),
either move the files into that directory or rerun with `--org com.gscamera`.

## 4. AndroidManifest

Open `app/android/app/src/main/AndroidManifest.xml` and paste the contents
of `_template/android_native/AndroidManifest_additions.xml` into the
`<manifest>` element, before `<application>`.

## 5. Bump min SDK

In `app/android/app/build.gradle.kts` (or `.gradle`), set:

```
minSdk = 26       // Camera2 manual lock features want API 26+
targetSdk = 34
```

## 6. Run on device

```
flutter devices             # confirm Android phone is detected
flutter run -d <device-id>  # builds & launches
```

For release APK:

```
flutter build apk --release
```

The signed APK ends up in `app/build/app/outputs/flutter-apk/`.
