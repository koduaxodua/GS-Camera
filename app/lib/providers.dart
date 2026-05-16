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
