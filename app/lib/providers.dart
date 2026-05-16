import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/capture_coordinator.dart';
import 'core/coverage_tracker.dart';
import 'core/sensor_manager.dart';
import 'models/capture_mode.dart';
import 'services/camera_service.dart';

/// Null means Smart mode. A concrete value pins the capture mode.
final selectedModeProvider = StateProvider<CaptureMode?>((ref) => null);

final cameraServiceProvider = Provider<CameraService>((ref) {
  return CameraService.instance;
});

final sensorManagerProvider = Provider<SensorManager>((ref) {
  final sensors = SensorManager();
  ref.onDispose(sensors.dispose);
  return sensors;
});

final captureCoordinatorProvider =
    ChangeNotifierProvider.autoDispose<CaptureCoordinator>((ref) {
  final coordinator = CaptureCoordinator(
    selectedMode: ref.read(selectedModeProvider),
    cameraService: ref.read(cameraServiceProvider),
    sensorManager: ref.read(sensorManagerProvider),
    coverageTracker: ref.read(coverageTrackerProvider.notifier),
  );
  Future<void>.microtask(coordinator.start);
  return coordinator;
});

final onboardingSeenProvider = StateProvider<bool>((ref) => false);

/// Exposes current sensor state (yaw, angular velocity, accelerometer variance).
/// Use this in UI widgets that need real-time sensor data.
final sensorProvider = StreamProvider<SensorSnapshot>((ref) {
  final sensorManager = ref.watch(sensorManagerProvider);
  return sensorManager.stream;
});

/// Exposes current camera status (active lens, luminance, preview stream).
final cameraStatusProvider = StreamProvider<CameraStatus>((ref) {
  final cameraService = ref.watch(cameraServiceProvider);
  return cameraService.previewFrames.map((frame) => CameraStatus(
        lensType: cameraService.currentLensType,
        luminance: frame.meanLuminance,
        previewTextureId: cameraService.config?.textureId ?? -1,
      ));
});

/// Tracks overall capture state (scanning/not scanning, phase, photo count).
final captureStateProvider = Provider<CaptureStateData>((ref) {
  final coordinator = ref.watch(captureCoordinatorProvider);
  return CaptureStateData(
    isScanning: coordinator.state == CaptureState.capturing,
    phase: coordinator.phase,
    photoCount: coordinator.shots.length,
    coveragePercent: ref.watch(coverageTrackerProvider).coveragePercent,
  );
});

/// Snapshot of camera status for UI consumption.
class CameraStatus {
  const CameraStatus({
    required this.lensType,
    required this.luminance,
    required this.previewTextureId,
  });

  final CameraLensType lensType;
  final double luminance;
  final int previewTextureId;
}

/// Snapshot of capture state for UI consumption.
class CaptureStateData {
  const CaptureStateData({
    required this.isScanning,
    required this.phase,
    required this.photoCount,
    required this.coveragePercent,
  });

  final bool isScanning;
  final CapturePhase phase;
  final int photoCount;
  final double coveragePercent;
}
