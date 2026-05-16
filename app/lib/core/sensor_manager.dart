import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math_64.dart';

/// Streaming sensor state, updated at ~50 Hz.
class SensorSnapshot {
  SensorSnapshot({
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.rollDeg,
    required this.angularSpeedDegPerSec,
    required this.linearAccelMag,
    required this.position,
    required this.timestampMs,
  });

  final double azimuthDeg;
  final double elevationDeg;
  final double rollDeg;

  /// Magnitude of angular velocity vector — used for "moving too fast" check.
  final double angularSpeedDegPerSec;

  /// Magnitude of linear acceleration with gravity removed; high = jerky.
  final double linearAccelMag;

  /// Approximate translation since session start. Integrated from
  /// gravity-corrected accel — drifts a lot, only useful as a coarse hint.
  final Vector3 position;

  final int timestampMs;
}

/// Subscribes to gyro/accelerometer streams and emits fused [SensorSnapshot]s.
///
/// Uses Android's GAME_ROTATION_VECTOR via the sensors_plus rotation stream
/// where available; falls back to integrating gyro otherwise.
class SensorManager {
  SensorManager();

  final _controller = StreamController<SensorSnapshot>.broadcast();
  Stream<SensorSnapshot> get stream => _controller.stream;

  StreamSubscription? _gyroSub;
  StreamSubscription? _accelSub;
  StreamSubscription? _userAccelSub;
  StreamSubscription? _magSub;
  StreamSubscription? _nativeMotionSub;

  // Orientation tracked as a quaternion, integrated from gyro deltas.
  Quaternion _orientation = Quaternion.identity();
  Vector3 _velocity = Vector3.zero();
  Vector3 _position = Vector3.zero();

  int? _lastGyroNs;
  int? _lastAccelNs;
  Vector3 _lastUserAccel = Vector3.zero();
  Vector3 _lastGravity = Vector3(0, 9.81, 0);
  double _angularSpeed = 0.0;

  /// Slow exponentially-smoothed reference yaw (radians, 0 = session start
  /// heading) computed from magnetometer + gravity. Used by the
  /// complementary filter to undo gyro drift over long sessions.
  double? _emaReferenceYaw;
  double? _initialMagHeading;
  double? _nativeAzimuthDeg;
  double? _nativeElevationDeg;
  double? _nativeRollDeg;
  int? _lastNativeMotionMs;
  static const double _magCorrectionAlpha = 0.02; // ~50-sample time const
  static const double _magEmaAlpha = 0.05;
  static const _motionEvents = EventChannel('gs_camera/motion');

  /// Reset position/orientation to identity. Called at session start.
  void resetSessionFrame() {
    _orientation = Quaternion.identity();
    _velocity = Vector3.zero();
    _position = Vector3.zero();
    _lastGyroNs = null;
    _lastAccelNs = null;
    _emaReferenceYaw = null;
    _initialMagHeading = null;
    _nativeAzimuthDeg = null;
    _nativeElevationDeg = null;
    _nativeRollDeg = null;
    _lastNativeMotionMs = null;
  }

  Future<void> start() async {
    resetSessionFrame();
    _nativeMotionSub =
        _motionEvents.receiveBroadcastStream().listen(_onNativeMotion);
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen(_onGyro);
    _accelSub =
        accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
            .listen(_onAccel);
    _userAccelSub = userAccelerometerEventStream(
            samplingPeriod: SensorInterval.gameInterval)
        .listen(_onUserAccel);
    _magSub = magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval)
        .listen(_onMagnetometer, onError: (_) {/* device w/o mag is fine */});
  }

  Future<void> stop() async {
    await _nativeMotionSub?.cancel();
    await _gyroSub?.cancel();
    await _accelSub?.cancel();
    await _userAccelSub?.cancel();
    await _magSub?.cancel();
    _nativeMotionSub = null;
    _gyroSub = null;
    _accelSub = null;
    _userAccelSub = null;
    _magSub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  void _onNativeMotion(dynamic event) {
    final m = (event as Map).cast<String, dynamic>();
    _nativeAzimuthDeg = (m['azimuth_deg'] as num).toDouble();
    _nativeElevationDeg = (m['elevation_deg'] as num).toDouble();
    _nativeRollDeg = (m['roll_deg'] as num).toDouble();
    _lastNativeMotionMs = (m['timestamp_ms'] as num).toInt();
    _emit();
  }

  void _onGyro(GyroscopeEvent e) {
    final nowNs = DateTime.now().microsecondsSinceEpoch * 1000;
    final last = _lastGyroNs;
    _lastGyroNs = nowNs;
    if (last == null) return;
    final dt = (nowNs - last) / 1e9;
    if (dt <= 0 || dt > 0.5) return;

    final omega = Vector3(e.x, e.y, e.z); // rad/s
    final omegaMag = omega.length;
    _angularSpeed = omegaMag * 180.0 / math.pi;

    if (omegaMag > 1e-6) {
      final theta = omegaMag * dt;
      final axis = omega / omegaMag;
      final dq = Quaternion.axisAngle(axis, theta);
      _orientation = (_orientation * dq).normalized();
    }

    // Complementary filter: blend the gyro-integrated yaw toward the slow
    // magnetometer reference so a long session doesn't drift bins out of
    // alignment with the real world. The mag correction is intentionally
    // tiny (α ≈ 0.02) — fast enough to undo drift over a minute of capture,
    // slow enough not to twitch when the field is briefly disturbed by
    // walking past appliances.
    final ref = _emaReferenceYaw;
    if (ref != null && _initialMagHeading != null) {
      final cameraForward = _orientation.rotated(Vector3(0, 0, -1));
      final integratedYaw = math.atan2(cameraForward.x, -cameraForward.z);
      var diff = ref - integratedYaw;
      while (diff > math.pi) {
        diff -= 2 * math.pi;
      }
      while (diff < -math.pi) {
        diff += 2 * math.pi;
      }
      if (diff.abs() > 0.0005) {
        final correction = Quaternion.axisAngle(
          Vector3(0, 1, 0),
          diff * _magCorrectionAlpha,
        );
        _orientation = (correction * _orientation).normalized();
      }
    }

    _emit();
  }

  void _onUserAccel(UserAccelerometerEvent e) {
    final nowNs = DateTime.now().microsecondsSinceEpoch * 1000;
    final last = _lastAccelNs;
    _lastAccelNs = nowNs;
    _lastUserAccel = Vector3(e.x, e.y, e.z);
    if (last == null) return;
    final dt = (nowNs - last) / 1e9;
    if (dt <= 0 || dt > 0.5) return;

    // Integrate user acceleration (gravity already removed by Android).
    // This drifts heavily — tolerable only over short capture sessions.
    _velocity += _lastUserAccel * dt;
    // Apply mild damping so a stationary phone with sensor noise drifts less.
    _velocity *= 0.95;
    _position += _velocity * dt;
  }

  void _onAccel(AccelerometerEvent e) {
    // Cache gravity vector with a slow EMA so we can level the magnetometer
    // reading. Sudden acceleration spikes are smoothed away.
    final g = Vector3(e.x, e.y, e.z);
    _lastGravity = _lastGravity * 0.92 + g * 0.08;
  }

  /// Magnetometer fusion. We expect to be roughly portrait, so we compute
  /// the tilt-compensated heading by projecting the geomagnetic vector
  /// onto the horizontal plane defined by gravity, then take its yaw.
  ///
  /// We treat the heading at the very first sample as "0" so the rest of
  /// the app keeps its session-relative azimuth model intact.
  void _onMagnetometer(MagnetometerEvent e) {
    final mag = Vector3(e.x, e.y, e.z);
    final fieldStrength = mag.length;
    // Skip wildly-off readings — being right next to a fridge or laptop
    // throws the field 5-10× normal and corrupts the heading estimate.
    if (fieldStrength < 20 || fieldStrength > 80) return;

    final gravity = _lastGravity.normalized();
    if (gravity.length2 < 0.5) return;

    // East = gravity × magneticNorth (right-hand rule), North = east × gravity.
    final east = gravity.cross(mag).normalized();
    if (east.length2 < 1e-6) return;
    final northH = east.cross(gravity).normalized();

    // Project the camera-forward (-Z device) onto the horizontal plane and
    // measure its angle relative to magnetic north.
    final cameraForward = _orientation.rotated(Vector3(0, 0, -1));
    final fwdHoriz = cameraForward - gravity * cameraForward.dot(gravity);
    if (fwdHoriz.length2 < 1e-3) return;
    final yaw = math.atan2(
      fwdHoriz.dot(east),
      fwdHoriz.dot(northH),
    );

    // Stash the very first reading so subsequent corrections are
    // session-relative (matches the rest of the app's azimuth conventions).
    _initialMagHeading ??= yaw;
    final relative = yaw - _initialMagHeading!;
    final wrapped =
        ((relative + math.pi) % (2 * math.pi) + 2 * math.pi) % (2 * math.pi) -
            math.pi;

    final prev = _emaReferenceYaw;
    if (prev == null) {
      _emaReferenceYaw = wrapped;
    } else {
      // Wrap-aware EMA — blend toward `wrapped` along the shortest arc so
      // we don't get a 360° wobble when the heading crosses the seam.
      var delta = wrapped - prev;
      while (delta > math.pi) {
        delta -= 2 * math.pi;
      }
      while (delta < -math.pi) {
        delta += 2 * math.pi;
      }
      _emaReferenceYaw = prev + delta * _magEmaAlpha;
    }
  }

  void _emit() {
    final nativeAgeMs = _lastNativeMotionMs == null
        ? 999999
        : DateTime.now().millisecondsSinceEpoch - _lastNativeMotionMs!;
    if (_nativeAzimuthDeg != null && nativeAgeMs < 500) {
      _controller.add(SensorSnapshot(
        azimuthDeg: _wrap360(_nativeAzimuthDeg!),
        elevationDeg: _nativeElevationDeg!,
        rollDeg: _nativeRollDeg!,
        angularSpeedDegPerSec: _angularSpeed,
        linearAccelMag: _lastUserAccel.length,
        position: _position.clone(),
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ));
      return;
    }

    // Map the orientation quaternion to user-meaningful angles by working
    // with the camera-forward and world-up directions directly. This is
    // robust against gimbal lock and avoids the axis-naming confusion of a
    // raw Tait-Bryan extraction.
    //
    // Phone in portrait (the only orientation we support for now):
    //   - Camera faces out of the back of the phone, i.e. -Z in device coords.
    //   - Top of the screen is +Y in device coords.
    //
    // Panning the phone left↔right is rotation around device Y, which moves
    // the camera-forward vector around the horizontal plane → AZIMUTH.
    // Tilting the phone up↔down is rotation around device X, which lifts
    // the camera-forward vector above or below the horizon → ELEVATION.
    // Twisting the phone in your hand is rotation around device Z and only
    // matters for the bubble level → ROLL.
    final cameraForward = _orientation.rotated(Vector3(0, 0, -1));
    final azimuthRad = math.atan2(cameraForward.x, -cameraForward.z);
    final elevationRad = math.asin(cameraForward.y.clamp(-1.0, 1.0));

    final worldUpInCamera = _orientation.inverted().rotated(Vector3(0, 1, 0));
    final rollRad = math.atan2(-worldUpInCamera.x, worldUpInCamera.y);

    _controller.add(SensorSnapshot(
      azimuthDeg: _wrap360(azimuthRad * 180.0 / math.pi),
      elevationDeg: elevationRad * 180.0 / math.pi,
      rollDeg: rollRad * 180.0 / math.pi,
      angularSpeedDegPerSec: _angularSpeed,
      linearAccelMag: _lastUserAccel.length,
      position: _position.clone(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  static double _wrap360(double d) {
    var v = d % 360.0;
    if (v < 0) v += 360.0;
    return v;
  }
}
