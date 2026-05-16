import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/capture_mode.dart';
import '../models/photo_meta.dart';
import '../services/blur_detector.dart';
import '../services/camera_service.dart';
import '../services/lens_dirt_detector.dart';
import '../services/lighting_analyzer.dart';
import 'coverage_map.dart';
import 'sensor_manager.dart';

/// Lifecycle phases of a capture session, exposed to the UI.
enum CaptureState {
  idle,
  preflight,    // analysing lens cleanliness + lighting
  guidance,     // user must fix something before we start
  locking,      // AE/AF/AWB sweep, then lock
  capturing,    // main loop, taking photos
  exporting,    // copying files + writing sidecar JSON
  complete,
}

/// Hints surfaced to the user. Most capture sessions surface zero of these.
enum GuidanceHint {
  none,
  wipeLens,
  addLight,
  reduceDirectLight,
  moveSlower,
  holdSteadier,
  continueMoving,
  alreadyCovered,
  lookAtGap,
}

/// The brain. Subscribes to sensor + preview-frame streams, decides when
/// to fire the shutter, and surfaces guidance to the UI.
///
/// Designed to be a `ChangeNotifier` so the UI can listen with `Provider`
/// or `ListenableBuilder` and rebuild on state changes.
class CaptureCoordinator extends ChangeNotifier {
  CaptureCoordinator({
    required this.mode,
    SensorManager? sensorManager,
    CameraService? cameraService,
  })  : sensors = sensorManager ?? SensorManager(),
        camera = cameraService ?? CameraService.instance;

  final CaptureMode mode;
  final SensorManager sensors;
  final CameraService camera;

  final coverage = CoverageMap();
  final List<PhotoMeta> shots = [];

  CaptureState _state = CaptureState.idle;
  CaptureState get state => _state;

  GuidanceHint _hint = GuidanceHint.none;
  GuidanceHint get hint => _hint;

  CameraConfig? _config;
  CameraConfig? get config => _config;

  SensorSnapshot? _lastSensor;
  SensorSnapshot? get lastSensor => _lastSensor;

  // Trigger gating thresholds (degrees / metres / sec).
  static const _maxAngularSpeed = 30.0;
  static const _maxLinearAccel = 1.5;
  static const _hintCooldown = Duration(seconds: 2);

  // State for trigger logic.
  double _azimuthAtLastShot = 0;
  double _elevationAtLastShot = 0;
  ({double x, double y, double z}) _positionAtLastShot = (x: 0, y: 0, z: 0);
  int _consecutiveBlurRejects = 0;
  DateTime _lastShotAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _hintShownAt = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription? _sensorSub;
  StreamSubscription? _frameSub;

  /// Buffer of the latest preview frame used for blur scoring at trigger
  /// time. Only the most recent frame is kept.
  PreviewFrame? _latestPreview;
  double _latestSharpness = double.infinity;

  Future<void> start() async {
    _setState(CaptureState.preflight);

    await camera.initSession().then((c) => _config = c);
    await sensors.start();

    // Run pre-flight on the first ~1 second of preview frames before
    // accepting any captures.
    final preflight = _PreflightCollector();
    final preSub = camera.previewFrames.listen(preflight.add);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await preSub.cancel();

    final preflightHint = preflight.evaluate();
    if (preflightHint != GuidanceHint.none) {
      _hint = preflightHint;
      _setState(CaptureState.guidance);
      return; // UI shows the hint; user calls [resumeAfterFix] when ready.
    }

    await _enterCapture();
  }

  /// Called by UI when user has acknowledged the guidance hint.
  Future<void> resumeAfterFix() async {
    _setState(CaptureState.locking);
    final cfg = await camera.recalibrate();
    _config = cfg;
    await _enterCapture();
  }

  Future<void> _enterCapture() async {
    sensors.resetSessionFrame();
    _setState(CaptureState.capturing);
    _sensorSub = sensors.stream.listen(_onSensor);
    _frameSub = camera.previewFrames.listen(_onFrame);
  }

  Future<List<PhotoMeta>> finish() async {
    await _sensorSub?.cancel();
    await _frameSub?.cancel();
    await sensors.stop();
    await camera.dispose();
    _setState(CaptureState.complete);
    return shots;
  }

  void _onFrame(PreviewFrame frame) {
    _latestPreview = frame;
    _latestSharpness = BlurDetector.laplacianVariance(
      frame.luma,
      frame.width,
      frame.height,
    );
  }

  void _onSensor(SensorSnapshot s) {
    _lastSensor = s;

    if (_state != CaptureState.capturing) {
      notifyListeners();
      return;
    }

    final cfg = _config;
    if (cfg == null) return;

    final angularDelta = _shortestArc(_azimuthAtLastShot, s.azimuthDeg);
    final pos = s.position;
    final dx = pos.x - _positionAtLastShot.x;
    final dy = pos.y - _positionAtLastShot.y;
    final dz = pos.z - _positionAtLastShot.z;
    final translation = (dx * dx + dy * dy + dz * dz);
    final translationMeters = translation > 0 ? translation : 0.0;

    final rotationOk = angularDelta >= mode.rotationStepDegrees;
    final translationOk = mode.translationStepMeters.isFinite &&
        translationMeters >= (mode.translationStepMeters * mode.translationStepMeters);
    final motionTriggerOk = rotationOk || translationOk;

    final notMovingTooFast = s.angularSpeedDegPerSec < _maxAngularSpeed;
    final notShaky = s.linearAccelMag < _maxLinearAccel;

    final blurThreshold = BlurDetector.thresholdForIso(cfg.iso);
    final sharpEnough = _latestSharpness >= blurThreshold;

    final notRecent = DateTime.now().difference(_lastShotAt).inMilliseconds > 250;

    if (motionTriggerOk && notMovingTooFast && notShaky && sharpEnough && notRecent) {
      _fireCapture(s);
      _consecutiveBlurRejects = 0;
      _maybeClearHint();
    } else {
      // Surface guidance only after a problem persists.
      if (motionTriggerOk && !notMovingTooFast) {
        _maybeShowHint(GuidanceHint.moveSlower);
      } else if (motionTriggerOk && !notShaky) {
        _maybeShowHint(GuidanceHint.holdSteadier);
      } else if (motionTriggerOk && !sharpEnough) {
        _consecutiveBlurRejects++;
        if (_consecutiveBlurRejects >= 3) {
          _maybeShowHint(GuidanceHint.moveSlower);
        }
      }
      // Idle for too long?
      if (DateTime.now().difference(_lastShotAt).inSeconds > 5 &&
          shots.isNotEmpty) {
        final dir = coverage.suggestNextDirection();
        _maybeShowHint(
          dir == null ? GuidanceHint.continueMoving : GuidanceHint.lookAtGap,
        );
      }
    }
    notifyListeners();
  }

  Future<void> _fireCapture(SensorSnapshot s) async {
    _lastShotAt = DateTime.now();
    final path = await camera.capture();
    final filename = path.split(RegExp(r'[\\/]')).last;
    final cfg = _config!;
    final pos = s.position;
    final meta = PhotoMeta(
      index: shots.length + 1,
      filename: filename,
      timestampMs: s.timestampMs,
      azimuthDeg: s.azimuthDeg,
      elevationDeg: s.elevationDeg,
      rollDeg: s.rollDeg,
      position: (x: pos.x, y: pos.y, z: pos.z),
      sharpness: _latestSharpness,
      exposureLockValue: cfg.exposureValue,
      iso: cfg.iso,
      shutterSpeedNs: cfg.shutterSpeedNs,
    );
    shots.add(meta);
    coverage.recordShot(
      azimuthDeg: s.azimuthDeg,
      elevationDeg: s.elevationDeg,
    );
    _azimuthAtLastShot = s.azimuthDeg;
    _elevationAtLastShot = s.elevationDeg;
    _positionAtLastShot = (x: pos.x, y: pos.y, z: pos.z);
  }

  void _maybeShowHint(GuidanceHint h) {
    if (h == _hint) return;
    if (DateTime.now().difference(_hintShownAt) < _hintCooldown) return;
    _hint = h;
    _hintShownAt = DateTime.now();
  }

  void _maybeClearHint() {
    if (_hint != GuidanceHint.none) {
      _hint = GuidanceHint.none;
    }
  }

  void _setState(CaptureState s) {
    _state = s;
    notifyListeners();
  }

  static double _shortestArc(double from, double to) {
    final d = ((to - from) % 360 + 540) % 360 - 180;
    return d.abs();
  }

  @override
  void dispose() {
    _sensorSub?.cancel();
    _frameSub?.cancel();
    sensors.stop();
    camera.dispose();
    super.dispose();
  }
}

/// Helper that watches the first second of preview frames at session start.
class _PreflightCollector {
  final List<PreviewFrame> _frames = [];

  void add(PreviewFrame f) {
    if (_frames.length < 12) _frames.add(f);
  }

  GuidanceHint evaluate() {
    if (_frames.isEmpty) return GuidanceHint.none;
    // Use a frame from the middle of the buffer (after AE has settled a bit).
    final f = _frames[_frames.length ~/ 2];
    final lighting = LightingAnalyzer.analyse(f.luma);
    if (lighting.tooDark) return GuidanceHint.addLight;
    if (lighting.clippingExcess) return GuidanceHint.reduceDirectLight;
    final smudge = LensDirtDetector.scoreSmudges(f.luma, f.width, f.height);
    if (smudge > 0.4) return GuidanceHint.wipeLens;
    return GuidanceHint.none;
  }
}
