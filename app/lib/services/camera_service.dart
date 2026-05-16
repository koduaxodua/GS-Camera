import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';

import '../core/coverage_tracker.dart';

class CameraService {
  CameraService._();
  static final CameraService instance = CameraService._();

  static const _method = MethodChannel('gs_camera/control');
  static const _events = EventChannel('gs_camera/preview_frames');

  Stream<PreviewFrame>? _previewFrames;
  double _lastPreviewLuminance = 0;
  CameraConfig? _lastConfig;
  List<CameraInventoryItem> _cameraInventory = const [];

  List<CameraInventoryItem> get cameraInventory => _cameraInventory;

  Future<CameraConfig> initSession(
      {CameraLensType camera = CameraLensType.main}) async {
    final m = await _method.invokeMapMethod<String, dynamic>(
      'initSession',
      {'camera_index': camera.cameraIndex},
    );
    return _remember(CameraConfig.fromMap(m!));
  }

  Future<CameraConfig> switchCamera(CameraLensType camera) async {
    return switchCameraIndex(camera.cameraIndex);
  }

  Future<CameraConfig> switchCameraIndex(int index) async {
    final m = await _method.invokeMapMethod<String, dynamic>(
      'selectCamera',
      {'camera_index': index},
    );
    return _remember(CameraConfig.fromMap(m!));
  }

  Future<String> capture() async {
    final r = await _method.invokeMethod<String>('capture');
    return r!;
  }

  Future<CameraConfig> recalibrate() async {
    final m = await _method.invokeMapMethod<String, dynamic>('recalibrate');
    return _remember(CameraConfig.fromMap(m!));
  }

  Future<void> dispose() async {
    await _method.invokeMethod<void>('dispose');
  }

  Future<double> getPreviewLuminance() async => _lastPreviewLuminance;

  Future<List<CameraInventoryItem>> getCameraList() async {
    final raw = await _method.invokeListMethod<dynamic>('getCameraList');
    final inventory = (raw ?? const [])
        .whereType<Map>()
        .map(
            (item) => CameraInventoryItem.fromMap(item.cast<String, dynamic>()))
        .toList(growable: false);
    _cameraInventory = inventory;
    return inventory;
  }

  Future<CameraIntrinsics> getIntrinsics(CameraLensType camera) async {
    final m = await _method.invokeMapMethod<String, dynamic>(
      'getIntrinsics',
      {'camera_index': camera.cameraIndex},
    );
    return CameraIntrinsics.fromMap(m ?? const {});
  }

  Future<Map<String, CameraIntrinsics>> getAllIntrinsics() async {
    final out = <String, CameraIntrinsics>{};
    final cameras = _lastConfig?.availableLenses ?? const [CameraLensType.main];
    for (final camera in cameras) {
      out[camera.exportName] = await getIntrinsics(camera);
    }
    return out;
  }

  CameraConfig _remember(CameraConfig config) {
    _lastConfig = config;
    if (config.cameraInventory.isNotEmpty) {
      _cameraInventory = config.cameraInventory;
    }
    return config;
  }

  Stream<PreviewFrame> get previewFrames {
    _previewFrames ??= _events.receiveBroadcastStream().map((dynamic e) {
      final m = (e as Map).cast<String, dynamic>();
      final frame = PreviewFrame(
        luma: m['luma'] as Uint8List,
        width: m['width'] as int,
        height: m['height'] as int,
        timestampMs: m['timestamp_ms'] as int,
      );
      _lastPreviewLuminance = frame.meanLuminance;
      return frame;
    }).asBroadcastStream();
    return _previewFrames!;
  }
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
    required this.textureId,
    required this.displayPreviewWidth,
    required this.displayPreviewHeight,
    required this.sensorOrientation,
    required this.cameraIndex,
    required this.cameraName,
    required this.cameraId,
    required this.focalLengthMm,
    required this.availableLenses,
    required this.cameraInventory,
  });

  factory CameraConfig.fromMap(Map<String, dynamic> m) => CameraConfig(
        iso: (m['iso'] as num?)?.toInt() ?? 0,
        shutterSpeedNs: (m['shutter_speed_ns'] as num?)?.toInt() ?? 0,
        exposureValue: (m['exposure_value'] as num?)?.toDouble() ?? 0,
        focusDistance: (m['focus_distance'] as num?)?.toDouble() ?? 0,
        previewWidth: (m['preview_width'] as num?)?.toInt() ?? 0,
        previewHeight: (m['preview_height'] as num?)?.toInt() ?? 0,
        captureWidth: (m['capture_width'] as num?)?.toInt() ?? 0,
        captureHeight: (m['capture_height'] as num?)?.toInt() ?? 0,
        textureId: (m['texture_id'] as num?)?.toInt() ?? -1,
        displayPreviewWidth: (m['display_preview_width'] as num?)?.toInt() ?? 0,
        displayPreviewHeight:
            (m['display_preview_height'] as num?)?.toInt() ?? 0,
        sensorOrientation: (m['sensor_orientation'] as num?)?.toInt() ?? 0,
        cameraIndex: (m['camera_index'] as num?)?.toInt() ?? 1,
        cameraName: m['camera_name'] as String? ?? 'main',
        cameraId: m['camera_id'] as String? ?? '',
        focalLengthMm: (m['focal_length_mm'] as num?)?.toDouble() ?? 0,
        availableLenses: _parseAvailableLenses(m['available_lenses']),
        cameraInventory: _parseCameraInventory(m['camera_inventory']),
      );

  final int iso;
  final int shutterSpeedNs;
  final double exposureValue;
  final double focusDistance;
  final int previewWidth;
  final int previewHeight;
  final int captureWidth;
  final int captureHeight;
  final int textureId;
  final int displayPreviewWidth;
  final int displayPreviewHeight;
  final int sensorOrientation;
  final int cameraIndex;
  final String cameraName;
  final String cameraId;
  final double focalLengthMm;
  final List<CameraLensType> availableLenses;
  final List<CameraInventoryItem> cameraInventory;

  CameraLensType get lensType => CameraLensType.fromExportName(cameraName);

  /// Legacy field: availableLenses reflects native labels. We compute a more
  /// conservative `hasTeleCamera` using actual focal lengths so the app
  /// doesn't try to use a Tele mode when no reasonably longer focal exists.
  bool get hasTeleCamera => teleAvailableFromInventory;

  bool supports(CameraLensType lens) => lens == CameraLensType.tele
      ? hasTeleCamera
      : availableLenses.contains(lens);

  /// Determine tele availability from actual camera inventory focal lengths.
  /// Tele is considered present only if one of the other cameras has a
  /// focal length noticeably longer than the main lens and native marked it
  /// as real. This prevents Main fallback from being exported as Tele.
  bool get teleAvailableFromInventory {
    try {
      if (cameraInventory.isEmpty) return false;
      // Find main focal length from inventory; fall back to top-level focal.
      final mainItem = cameraInventory.firstWhere(
        (c) => c.cameraName == 'main',
        orElse: () => cameraInventory.first,
      );
      final mainFocal =
          mainItem.focalLengthMm > 0 ? mainItem.focalLengthMm : focalLengthMm;
      for (final item in cameraInventory) {
        if (item.cameraId == mainItem.cameraId) continue;
        final delta = item.focalLengthMm - mainFocal;
        if (item.realTele && item.focalLengthMm > 7.0 && delta > 1.5) {
          developer.log(
              'tele detected: ${item.cameraName} focal=${item.focalLengthMm}mm main=${mainFocal}mm',
              name: 'gs_camera');
          return true;
        }
      }
      return false;
    } catch (e) {
      developer.log('teleAvailableFromInventory error: $e', name: 'gs_camera');
      return false;
    }
  }

  static List<CameraLensType> _parseAvailableLenses(Object? value) {
    final raw = value is List ? value : const ['main'];
    final lenses = raw
        .whereType<String>()
        .map(CameraLensType.fromExportName)
        .toSet()
        .toList(growable: false);
    return lenses.isEmpty ? const [CameraLensType.main] : lenses;
  }

  static List<CameraInventoryItem> _parseCameraInventory(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map(
            (item) => CameraInventoryItem.fromMap(item.cast<String, dynamic>()))
        .toList(growable: false);
  }
}

class CameraInventoryItem {
  const CameraInventoryItem({
    required this.cameraId,
    required this.cameraName,
    required this.focalLengthMm,
    this.sensorWidthMm = 0,
    this.sensorHeightMm = 0,
    this.activeArrayWidth = 0,
    this.activeArrayHeight = 0,
    this.realTele = false,
  });

  factory CameraInventoryItem.fromMap(Map<String, dynamic> m) =>
      CameraInventoryItem(
        cameraId: m['camera_id'] as String? ?? '',
        cameraName: m['camera_name'] as String? ?? 'main',
        focalLengthMm: (m['focal_length_mm'] as num?)?.toDouble() ?? 0,
        sensorWidthMm: (m['sensor_width_mm'] as num?)?.toDouble() ?? 0,
        sensorHeightMm: (m['sensor_height_mm'] as num?)?.toDouble() ?? 0,
        activeArrayWidth: (m['active_array_width'] as num?)?.toInt() ?? 0,
        activeArrayHeight: (m['active_array_height'] as num?)?.toInt() ?? 0,
        realTele: m['real_tele'] == true,
      );

  final String cameraId;
  final String cameraName;
  final double focalLengthMm;
  final double sensorWidthMm;
  final double sensorHeightMm;
  final int activeArrayWidth;
  final int activeArrayHeight;
  final bool realTele;
}

class CameraIntrinsics {
  const CameraIntrinsics({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
  });

  factory CameraIntrinsics.fromMap(Map<String, dynamic> m) => CameraIntrinsics(
        fx: (m['fx'] as num?)?.toDouble() ?? 0,
        fy: (m['fy'] as num?)?.toDouble() ?? 0,
        cx: (m['cx'] as num?)?.toDouble() ?? 0,
        cy: (m['cy'] as num?)?.toDouble() ?? 0,
        width: (m['width'] as num?)?.toDouble() ?? 0,
        height: (m['height'] as num?)?.toDouble() ?? 0,
      );

  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
        'fx': fx,
        'fy': fy,
        'cx': cx,
        'cy': cy,
        'width': width,
        'height': height,
      };
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

  double get meanLuminance {
    if (luma.isEmpty) return 0;
    var sum = 0;
    for (final v in luma) {
      sum += v;
    }
    return sum / luma.length;
  }
}
