import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'dart:developer' as developer;
import 'package:path_provider/path_provider.dart';
import 'package:vector_math/vector_math_64.dart';

import '../models/capture_mode.dart';
import '../models/photo_meta.dart';
import '../services/blur_detector.dart';
import '../services/camera_service.dart';
import '../services/embedding_service.dart';
import '../services/texture_analyzer.dart';
import 'coverage_tracker.dart';
import 'sensor_manager.dart';

enum CaptureState {
  idle,
  preflight,
  locking,
  capturing,
  exporting,
  complete,
  failed,
}

enum CapturePhase {
  basicFill,
  qualityUpgrade,
  detailLock,
}

class CaptureGuidance {
  const CaptureGuidance({
    required this.text,
    required this.iconName,
    this.arrowDegrees,
  });

  final String text;
  final String iconName;
  final double? arrowDegrees;
}

class CaptureCoordinator extends ChangeNotifier {
  CaptureCoordinator({
    required CaptureMode? selectedMode,
    required CameraService cameraService,
    required SensorManager sensorManager,
    required this.coverageTracker,
    EmbeddingService? embeddingService,
  })  : _selectedMode = selectedMode,
        camera = cameraService,
        sensors = sensorManager,
        embedder = embeddingService ?? EmbeddingService.instance;

  final CameraService camera;
  final SensorManager sensors;
  final CoverageTracker coverageTracker;
  final EmbeddingService embedder;

  final List<PhotoMeta> shots = [];

  CaptureState _state = CaptureState.idle;
  CaptureState get state => _state;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  CaptureMode? _selectedMode;
  CaptureMode _detectedMode = CaptureMode.spherical;
  CaptureMode get mode => _selectedMode ?? _detectedMode;
  bool get smartMode => _selectedMode == null;

  CameraConfig? _config;
  CameraConfig? get config => _config;

  SensorSnapshot? _lastSensor;
  SensorSnapshot? get lastSensor => _lastSensor;

  CapturePhase _phase = CapturePhase.basicFill;
  CapturePhase get phase => _phase;

  CameraLensType _activeCamera = CameraLensType.main;
  CameraLensType get activeCamera => _activeCamera;

  CaptureGuidance _guidance =
      const CaptureGuidance(text: 'Move slowly', iconName: 'explore');
  CaptureGuidance get guidance => _guidance;

  double _latestLuminance = 0;
  double get latestLuminance => _latestLuminance;

  double _latestSharpness = 0;
  double get latestSharpness => _latestSharpness;

  double _latestTexture = 0;
  double get latestTexture => _latestTexture;

  int _dedupedCount = 0;
  int get dedupedCount => _dedupedCount;
  int get keptCount => shots.where((p) => p.keptInExport).length;
  bool get hasPhotos => shots.isNotEmpty;
  bool get hasTeleCamera => _config?.hasTeleCamera ?? false;

  bool _autoFinishActive = false;
  bool get autoFinishActive => _autoFinishActive;

  bool get canManualFinish =>
      _state != CaptureState.exporting &&
      _state != CaptureState.complete &&
      _state != CaptureState.failed;

  static const _hudNotifyInterval = Duration(milliseconds: 66);
  static const _minShotInterval = Duration(milliseconds: 500);

  final Map<CameraLensType, double> _lastYawByCamera = {};
  final Map<CameraLensType, DateTime> _lastShotByCamera = {};
  StreamSubscription? _sensorSub;
  StreamSubscription? _frameSub;
  DateTime _lastShotAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHudNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _steadySince;
  DateTime _lastFocusRecalibrationAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposing = false;
  bool _switchingCamera = false;
  bool _recalibratingFocus = false;
  bool _liveDedupRunning = false;
  int _softFrameStreak = 0;

  Future<void> start() async {
    if (_disposing) return;
    _setState(CaptureState.preflight);
    coverageTracker.reset();
    unawaited(_purgeTmpDir());
    try {
      _activeCamera = CameraLensType.main;
      _config = await camera.initSession(camera: _activeCamera);
      _activeCamera = _config?.lensType ?? CameraLensType.main;
      if (_disposing) return;
      await sensors.start();
      if (_disposing) return;
      _frameSub = camera.previewFrames.listen(_onFrame);
      _sensorSub = sensors.stream.listen(_onSensor);
      _setState(CaptureState.capturing);
    } catch (e, st) {
      debugPrint('capture start failed: $e\n$st');
      _errorMessage = 'Could not start capture: $e';
      _setState(CaptureState.failed);
    }
  }

  void setMode(CaptureMode? mode) {
    _selectedMode = mode;
    _cancelAutoFinish();
    notifyListeners();
  }

  Future<void> forceCapture() async {
    if (_state != CaptureState.capturing) return;
    final sensor = _lastSensor ?? _fallbackSensorSnapshot();
    // Force capture should always use the currently active camera and
    // should not implicitly switch lenses. This avoids stalls when a
    // desired lens (e.g. tele) isn't present.
    developer.log('forceCapture invoked on active=${_activeCamera.name}',
        name: 'gs_camera.capture');
    await _fireCapture(sensor, force: true);
  }

  SensorSnapshot _fallbackSensorSnapshot() {
    developer.log(
        'forceCapture using fallback pose because sensors are not ready yet',
        name: 'gs_camera.capture');
    return SensorSnapshot(
      azimuthDeg: 0,
      elevationDeg: 0,
      rollDeg: 0,
      angularSpeedDegPerSec: 0,
      linearAccelMag: 0,
      position: Vector3.zero(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void addMore() {
    _cancelAutoFinish();
    _lastShotAt = DateTime.now();
    _setGuidance(const CaptureGuidance(text: 'Keep scanning', iconName: 'add'));
  }

  Future<List<PhotoMeta>> finish() async {
    _cancelAutoFinish();
    await _sensorSub?.cancel();
    await _frameSub?.cancel();
    await sensors.stop();
    await camera.dispose();
    _setState(CaptureState.exporting);
    for (var i = 0; i < 12 && _liveDedupRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await _runPostCaptureMlDedup();
    _setState(CaptureState.complete);
    return shots.where((p) => p.keptInExport).toList();
  }

  void _onFrame(PreviewFrame frame) {
    _latestLuminance = frame.meanLuminance;
    final variance = BlurDetector.laplacianVariance(
      frame.luma,
      frame.width,
      frame.height,
    );
    _latestSharpness = (variance / 160.0).clamp(0.0, 1.0);
    _latestTexture =
        TextureAnalyzer.score(frame.luma, frame.width, frame.height);
    _maybeRecalibrateFocus();
  }

  void _onSensor(SensorSnapshot sensor) {
    _lastSensor = sensor;
    if (_state != CaptureState.capturing) {
      _notifyThrottled();
      return;
    }

    _updateSmartMode(sensor);
    _updatePhaseAndCamera(sensor);
    _updateGuidance(sensor);
    _maybeFireSmartShutter(sensor);
    _notifyThrottled();
  }

  void _updateSmartMode(SensorSnapshot sensor) {
    if (!smartMode) return;
    if (shots.length < 6) return;
    final yawSpread = _estimateYawSpread();
    final movement = sensor.position.length;
    if (yawSpread > 300) {
      _detectedMode = CaptureMode.room;
    } else if (yawSpread > 80 && movement < 0.45) {
      _detectedMode = CaptureMode.object;
    } else {
      _detectedMode = CaptureMode.spherical;
    }
  }

  double _estimateYawSpread() {
    if (shots.isEmpty) return 0;
    final az = shots.map((s) => s.azimuthDeg).toList()..sort();
    if (az.length < 2) return 0;
    var largestGap = 0.0;
    for (var i = 0; i < az.length; i++) {
      final a = az[i];
      final b = i == az.length - 1 ? az.first + 360 : az[i + 1];
      largestGap = math.max(largestGap, b - a);
    }
    return 360 - largestGap;
  }

  void _updatePhaseAndCamera(SensorSnapshot sensor) {
    final coverage = coverageTracker.value.coveragePercent;
    final wantsTeleDetail = hasTeleCamera &&
        coverage >= 97 &&
        coverageTracker.needsDetail(
          sensor.azimuthDeg,
          sensor.elevationDeg,
          mode,
        );
    final nextPhase = wantsTeleDetail
        ? CapturePhase.detailLock
        : coverage < 97
            ? CapturePhase.qualityUpgrade
            : CapturePhase.basicFill;
    if (_phase != nextPhase) {
      developer.log(
          'phase_change from=${_phase.name} to=${nextPhase.name} coverage=${coverage.toStringAsFixed(1)}',
          name: 'gs_camera.capture');
    }
    _phase = nextPhase;

    final desiredCamera = switch (nextPhase) {
      CapturePhase.basicFill => CameraLensType.main,
      CapturePhase.qualityUpgrade => CameraLensType.main,
      CapturePhase.detailLock => CameraLensType.tele,
    };
    if (desiredCamera != _activeCamera) {
      unawaited(_switchCamera(desiredCamera));
    }
  }

  Future<void> _switchCamera(CameraLensType cameraType) async {
    if (_switchingCamera || _disposing) return;
    _switchingCamera = true;
    try {
      _setState(CaptureState.locking);
      final old = _activeCamera;
      _config = await camera.switchCamera(cameraType);
      _activeCamera = _config?.lensType ?? cameraType;
      developer.log('camera_switch from=${old.name} to=${_activeCamera.name}',
          name: 'gs_camera.capture');
      _setState(CaptureState.capturing);
    } catch (e) {
      debugPrint('camera switch failed: $e');
      _setState(CaptureState.capturing);
    } finally {
      _switchingCamera = false;
    }
  }

  void _maybeFireSmartShutter(SensorSnapshot sensor) {
    if (_switchingCamera) return;
    final now = DateTime.now();
    if (now.difference(_lastShotAt) < _minShotInterval) return;

    final commonLuminanceOk = _latestLuminance >= 20 && _latestLuminance <= 248;
    if (!commonLuminanceOk) return;

    final speedLimit = _phase == CapturePhase.detailLock ? 3.0 : 8.0;
    if (sensor.angularSpeedDegPerSec >= speedLimit) {
      _steadySince = null;
      return;
    }
    _steadySince ??= now;
    if (now.difference(_steadySince!) < const Duration(milliseconds: 220)) {
      return;
    }

    final yawDelta = _yawDeltaFor(_activeCamera, sensor.azimuthDeg);
    final targetNeedsQuality = coverageTracker.needsQuality(
      sensor.azimuthDeg,
      sensor.elevationDeg,
      mode,
    );
    final targetNeedsDetail = coverageTracker.needsDetail(
      sensor.azimuthDeg,
      sensor.elevationDeg,
      mode,
    );

    final shouldCapture = switch (_phase) {
      CapturePhase.basicFill => _mainShouldCapture(
          sensor: sensor,
          yawDelta: yawDelta,
          targetNeedsQuality: targetNeedsQuality,
        ),
      CapturePhase.qualityUpgrade => _mainShouldCapture(
          sensor: sensor,
          yawDelta: yawDelta,
          targetNeedsQuality: targetNeedsQuality,
        ),
      CapturePhase.detailLock => hasTeleCamera &&
          _activeCamera == CameraLensType.tele &&
          sensor.angularSpeedDegPerSec < 3 &&
          yawDelta > 3 &&
          targetNeedsDetail &&
          _latestSharpness >= 0.72 &&
          _latestTexture >= 0.10,
    };

    if (shouldCapture) {
      unawaited(_fireCapture(sensor, force: false));
    }
  }

  bool _mainShouldCapture({
    required SensorSnapshot sensor,
    required double yawDelta,
    required bool targetNeedsQuality,
  }) {
    return _activeCamera == CameraLensType.main &&
        sensor.angularSpeedDegPerSec < 8 &&
        yawDelta > _qualityStepForMode() &&
        (targetNeedsQuality || coverageTracker.value.coveragePercent >= 97) &&
        _latestSharpness >= _mainSharpnessThreshold() &&
        _latestTexture >= 0.12;
  }

  double _qualityStepForMode() {
    return switch (mode) {
      CaptureMode.room => 5,
      CaptureMode.object => 4,
      CaptureMode.spherical => 6,
    };
  }

  double _mainSharpnessThreshold() {
    if (shots.length < 10) return 0.50;
    return 0.58;
  }

  double _yawDeltaFor(CameraLensType cameraType, double yaw) {
    final last = _lastYawByCamera[cameraType];
    if (last == null) return 999;
    return _shortestArc(last, yaw);
  }

  Future<void> _fireCapture(SensorSnapshot sensor,
      {required bool force}) async {
    _lastShotAt = DateTime.now();
    final qualityAccepted = _qualityAcceptedFor(_activeCamera);
    try {
      final path = await camera.capture();
      final filename = path.split(RegExp(r'[\\/]')).last;
      // Decide camera label carefully: do not label as 'tele' unless the
      // current CameraConfig reports a genuine tele lens available.
      final cfg = _config;
      String cameraLabel;
      if (cfg != null) {
        if (cfg.teleAvailableFromInventory) {
          cameraLabel = cfg.cameraName;
        } else {
          // If tele is not actually available, never label photos as tele.
          cameraLabel = cfg.cameraName == 'tele' ? 'main' : cfg.cameraName;
        }
      } else {
        cameraLabel = _activeCamera.exportName;
      }

      final meta = PhotoMeta(
        index: shots.length + 1,
        filename: filename,
        absolutePath: path,
        timestampMs: sensor.timestampMs,
        azimuthDeg: sensor.azimuthDeg,
        elevationDeg: sensor.elevationDeg,
        rollDeg: sensor.rollDeg,
        position: (
          x: sensor.position.x,
          y: sensor.position.y,
          z: sensor.position.z,
        ),
        sharpness: _latestSharpness,
        textureScore: _latestTexture,
        exposureLockValue: cfg?.exposureValue ?? 0,
        iso: cfg?.iso ?? 0,
        shutterSpeedNs: cfg?.shutterSpeedNs ?? 0,
        camera: cameraLabel,
      );
      shots.add(meta);
      developer.log(
          'capture_saved count=${shots.length} camera=$cameraLabel path=$path',
          name: 'gs_camera.capture');
      _scheduleLiveDedup(meta);
      final recordedCamera = CameraLensType.fromExportName(cameraLabel);
      _activeCamera = recordedCamera;
      _lastYawByCamera[recordedCamera] = sensor.azimuthDeg;
      _lastShotByCamera[recordedCamera] = DateTime.now();
      coverageTracker.recordFrame(
        mode: mode,
        camera: recordedCamera,
        azimuthDeg: sensor.azimuthDeg,
        elevationDeg: sensor.elevationDeg,
        sharpness: _latestSharpness,
        textureScore: _latestTexture,
        qualityAccepted: force || qualityAccepted,
      );
      _cancelAutoFinish();
      _notifyThrottled(force: true);
    } catch (e, st) {
      debugPrint('capture failed: $e\n$st');
    }
  }

  bool _qualityAcceptedFor(CameraLensType cameraType) {
    final lumOk = _latestLuminance >= 20 && _latestLuminance <= 248;
    final textureThreshold = cameraType == CameraLensType.uw ? 0.10 : 0.12;
    final sharpThreshold = switch (cameraType) {
      CameraLensType.uw => 0.45,
      CameraLensType.main => _mainSharpnessThreshold(),
      CameraLensType.tele => 0.72,
    };
    return lumOk &&
        _latestSharpness >= sharpThreshold &&
        _latestTexture >= textureThreshold;
  }

  void _updateGuidance(SensorSnapshot sensor) {
    if (_phase == CapturePhase.detailLock && hasTeleCamera) {
      _setGuidance(const CaptureGuidance(
        text: 'Point at plain wall for detail',
        iconName: 'center_focus_strong',
      ));
      return;
    }
    if (_recalibratingFocus) {
      _setGuidance(const CaptureGuidance(
          text: 'Improving focus', iconName: 'center_focus_strong'));
      return;
    }
    if (sensor.angularSpeedDegPerSec > 8) {
      _setGuidance(const CaptureGuidance(text: 'Slow down', iconName: 'speed'));
      return;
    }
    if (sensor.linearAccelMag > 1.5) {
      _setGuidance(
          const CaptureGuidance(text: 'Hold steady', iconName: 'pan_tool'));
      return;
    }
    if (_latestLuminance > 0 && _latestLuminance < 20) {
      _setGuidance(
          const CaptureGuidance(text: 'Too dark', iconName: 'dark_mode'));
      return;
    }
    if (_latestLuminance > 248) {
      _setGuidance(
          const CaptureGuidance(text: 'Bright light', iconName: 'wb_sunny'));
      return;
    }
    if (_latestSharpness > 0 && _latestSharpness < 0.35) {
      _setGuidance(const CaptureGuidance(
          text: 'Focus soft', iconName: 'center_focus_weak'));
      return;
    }
    if (sensor.elevationDeg > 45) {
      _setGuidance(
          const CaptureGuidance(text: 'Look down', iconName: 'arrow_downward'));
    } else if (sensor.elevationDeg < -45) {
      _setGuidance(
          const CaptureGuidance(text: 'Look up', iconName: 'arrow_upward'));
    } else {
      _setGuidance(const CaptureGuidance(
        text: 'Ready',
        iconName: 'radio_button_checked',
      ));
    }
  }

  void _maybeRecalibrateFocus() {
    if (_disposing ||
        _switchingCamera ||
        _recalibratingFocus ||
        _state != CaptureState.capturing ||
        _activeCamera != CameraLensType.main) {
      return;
    }
    if (_latestSharpness <= 0) return;
    if (_latestSharpness < 0.42) {
      _softFrameStreak++;
    } else {
      _softFrameStreak = 0;
      return;
    }
    final now = DateTime.now();
    final earlySession = shots.length < 8;
    final badlySoft = _latestSharpness < 0.28;
    if (_softFrameStreak < 5 || (!earlySession && !badlySoft)) return;
    if (now.difference(_lastFocusRecalibrationAt).inSeconds < 4) return;
    _lastFocusRecalibrationAt = now;
    unawaited(_recalibrateFocus('soft_preview'));
  }

  Future<void> _recalibrateFocus(String reason) async {
    _recalibratingFocus = true;
    developer.log(
        'focus_recalibrate_start reason=$reason sharpness=$_latestSharpness shots=${shots.length}',
        name: 'gs_camera.capture');
    try {
      _config = await camera.recalibrate();
      developer.log('focus_recalibrate_done reason=$reason',
          name: 'gs_camera.capture');
    } catch (e) {
      developer.log('focus_recalibrate_failed reason=$reason error=$e',
          name: 'gs_camera.capture');
    } finally {
      _softFrameStreak = 0;
      _recalibratingFocus = false;
    }
  }

  void _setGuidance(CaptureGuidance guidance) {
    if (_guidance.text == guidance.text &&
        _guidance.iconName == guidance.iconName) {
      return;
    }
    _guidance = guidance;
  }

  void _cancelAutoFinish() {
    _autoFinishActive = false;
  }

  Future<void> _runPostCaptureMlDedup() async {
    if (!EmbeddingService.postCaptureDedupEnabled) return;
    final kept = <PhotoMeta>[];
    await embedder.warmup();
    if (!embedder.isReady) return;
    for (final meta in shots.where((p) => p.keptInExport)) {
      final file = File(meta.absolutePath);
      if (!await file.exists()) continue;
      final embedding = await embedder.embedJpeg(await file.readAsBytes());
      if (embedding == null) {
        kept.add(meta);
        continue;
      }
      meta.embedding = embedding;
      PhotoMeta? duplicate;
      var bestSim = -1.0;
      for (final existing in kept) {
        if (existing.embedding == null) continue;
        if (_shortestArc(existing.azimuthDeg, meta.azimuthDeg) > 12) continue;
        if ((existing.elevationDeg - meta.elevationDeg).abs() > 20) continue;
        final sim = EmbeddingService.cosineSimilarity(
          embedding,
          existing.embedding!,
        );
        if (sim > bestSim) {
          bestSim = sim;
          duplicate = existing;
        }
      }
      if (duplicate != null && bestSim >= mode.similarityThreshold) {
        final replace = meta.sharpness > duplicate.sharpness * 1.05;
        if (replace) {
          await _discardPhoto(duplicate);
          kept.remove(duplicate);
          kept.add(meta);
        } else {
          await _discardPhoto(meta);
        }
        _dedupedCount++;
      } else {
        kept.add(meta);
      }
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
  }

  void _scheduleLiveDedup(PhotoMeta meta) {
    if (shots.length < 5 || _liveDedupRunning || !meta.keptInExport) return;
    _liveDedupRunning = true;
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      try {
        final file = File(meta.absolutePath);
        if (!meta.keptInExport || !await file.exists()) return;
        final embedding = await embedder.embedJpeg(await file.readAsBytes());
        if (embedding == null) return;
        meta.embedding = embedding;
        PhotoMeta? duplicate;
        var bestSim = -1.0;
        for (final existing in shots.where((p) => p.keptInExport)) {
          if (identical(existing, meta)) continue;
          if (_shortestArc(existing.azimuthDeg, meta.azimuthDeg) > 8) continue;
          if ((existing.elevationDeg - meta.elevationDeg).abs() > 14) continue;
          if (existing.embedding == null) {
            final existingFile = File(existing.absolutePath);
            if (!await existingFile.exists()) continue;
            existing.embedding =
                await embedder.embedJpeg(await existingFile.readAsBytes());
          }
          if (existing.embedding == null) continue;
          final sim = EmbeddingService.cosineSimilarity(
            embedding,
            existing.embedding!,
          );
          if (sim > bestSim) {
            bestSim = sim;
            duplicate = existing;
          }
        }
        final threshold = math.max(mode.similarityThreshold + 0.03, 0.94);
        if (duplicate == null || bestSim < threshold) return;
        final replace = meta.sharpness > duplicate.sharpness * 1.08;
        await _discardPhoto(replace ? duplicate : meta);
        _dedupedCount++;
        developer.log(
          'live_dedup removed=${replace ? duplicate.index : meta.index} '
          'kept=${replace ? meta.index : duplicate.index} '
          'sim=${bestSim.toStringAsFixed(3)}',
          name: 'gs_camera.capture',
        );
        _notifyThrottled(force: true);
      } catch (e) {
        developer.log('live_dedup_skipped error=$e', name: 'gs_camera.capture');
      } finally {
        _liveDedupRunning = false;
      }
    }());
  }

  Future<void> _discardPhoto(PhotoMeta meta) async {
    meta.keptInExport = false;
    try {
      final f = File(meta.absolutePath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Best effort cleanup.
    }
  }

  Future<void> _purgeTmpDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return;
      final tmp = Directory('${ext.path}/Pictures/tmp');
      if (!await tmp.exists()) return;
      await for (final entity in tmp.list(followLinks: false)) {
        if (entity is File) {
          await entity.delete().catchError((_) => entity);
        }
      }
    } catch (_) {
      // Best effort only.
    }
  }

  void _setState(CaptureState next) {
    _state = next;
    notifyListeners();
  }

  void _notifyThrottled({bool force = false}) {
    if (_disposing) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastHudNotifyAt) < _hudNotifyInterval) {
      return;
    }
    _lastHudNotifyAt = now;
    notifyListeners();
  }

  static double _shortestArc(double from, double to) =>
      _signedArc(from, to).abs();

  static double _signedArc(double from, double to) {
    return ((to - from) % 360 + 540) % 360 - 180;
  }

  @override
  void dispose() {
    _disposing = true;
    _cancelAutoFinish();
    _sensorSub?.cancel();
    _frameSub?.cancel();
    sensors.stop();
    camera.dispose();
    super.dispose();
  }
}
