import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Thin Dart facade over the native Camera2 plugin (Android) we ship in
/// `android/app/src/main/kotlin/.../GsCameraPlugin.kt`. The native side
/// owns the camera session because Flutter's `camera` package can't reliably
/// lock AE/AF/AWB or disable HDR/scene modes — and those are the most
/// important features for postshot.
///
/// On iOS this will eventually be backed by an AVFoundation plugin with
/// the same method-channel surface.
class CameraService {
  CameraService._();
  static final CameraService instance = CameraService._();

  static const _method = MethodChannel('gs_camera/control');
  static const _events = EventChannel('gs_camera/preview_frames');

  /// Opens the back camera, configures preview + capture sessions, and
  /// runs an AE/AF/AWB sweep. Once this returns, exposure/focus/WB are
  /// locked and won't drift for the rest of the session.
  Future<CameraConfig> initSession() async {
    final m = await _method.invokeMapMethod<String, dynamic>('initSession');
    return CameraConfig.fromMap(m!);
  }

  /// Snap a full-resolution JPEG. Returns the absolute file path.
  Future<String> capture() async {
    final r = await _method.invokeMethod<String>('capture');
    return r!;
  }

  /// Re-run AE/AF/AWB sweep without tearing down the session — used when
  /// the user re-enters capture after the pre-flight told them to fix
  /// something (wipe lens, turn on a light).
  Future<CameraConfig> recalibrate() async {
    final m = await _method.invokeMapMethod<String, dynamic>('recalibrate');
    return CameraConfig.fromMap(m!);
  }

  /// Stop preview, release session.
  Future<void> dispose() async {
    await _method.invokeMethod<void>('dispose');
  }

  /// Stream of low-res grayscale Y-plane frames for on-device blur /
  /// lighting / lens-dirt analysis. Resolution is set by the native side
  /// (320×240 typical).
  Stream<PreviewFrame> get previewFrames =>
      _events.receiveBroadcastStream().map((dynamic e) {
        final m = (e as Map).cast<String, dynamic>();
        return PreviewFrame(
          luma: m['luma'] as Uint8List,
          width: m['width'] as int,
          height: m['height'] as int,
          timestampMs: m['timestamp_ms'] as int,
        );
      });
}

class CameraConfig {
  CameraConfig({
    required this.iso,
    required this.shutterSpeedNs,
    required this.exposureValue,
    required this.focusDistance,
    required this.previewWidth,
    required this.previewHeight,
    required this.captureWidth,
    required this.captureHeight,
  });

  factory CameraConfig.fromMap(Map<String, dynamic> m) => CameraConfig(
        iso: m['iso'] as int,
        shutterSpeedNs: m['shutter_speed_ns'] as int,
        exposureValue: (m['exposure_value'] as num).toDouble(),
        focusDistance: (m['focus_distance'] as num).toDouble(),
        previewWidth: m['preview_width'] as int,
        previewHeight: m['preview_height'] as int,
        captureWidth: m['capture_width'] as int,
        captureHeight: m['capture_height'] as int,
      );

  final int iso;
  final int shutterSpeedNs;
  final double exposureValue;
  final double focusDistance;
  final int previewWidth;
  final int previewHeight;
  final int captureWidth;
  final int captureHeight;
}

class PreviewFrame {
  PreviewFrame({
    required this.luma,
    required this.width,
    required this.height,
    required this.timestampMs,
  });

  final Uint8List luma;
  final int width;
  final int height;
  final int timestampMs;
}
