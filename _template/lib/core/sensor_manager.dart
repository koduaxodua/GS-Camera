import 'dart:async';
import 'dart:math' as math;

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

  // Orientation tracked as a quaternion, integrated from gyro deltas.
  Quaternion _orientation = Quaternion.identity();
  Vector3 _velocity = Vector3.zero();
  Vector3 _position = Vector3.zero();

  int? _lastGyroNs;
  int? _lastAccelNs;
  Vector3 _lastUserAccel = Vector3.zero();
  double _angularSpeed = 0.0;

  /// Reset position/orientation to identity. Called at session start.
  void resetSessionFrame() {
    _orientation = Quaternion.identity();
    _velocity = Vector3.zero();
    _position = Vector3.zero();
    _lastGyroNs = null;
    _lastAccelNs = null;
  }

  Future<void> start() async {
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen(_onGyro);
    _accelSub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen(_onAccel);
    _userAccelSub = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen(_onUserAccel);
  }

  Future<void> stop() async {
    await _gyroSub?.cancel();
    await _accelSub?.cancel();
    await _userAccelSub?.cancel();
    await _controller.close();
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
    // Used only for absolute roll/elevation reference relative to gravity,
    // which we currently derive from the orientation quaternion. Kept for
    // future correction/Madgwick fusion.
  }

  void _emit() {
    final euler = _quatToEuler(_orientation);
    _controller.add(SensorSnapshot(
      azimuthDeg: _wrap360(euler.yaw * 180.0 / math.pi),
      elevationDeg: euler.pitch * 180.0 / math.pi,
      rollDeg: euler.roll * 180.0 / math.pi,
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

  static ({double yaw, double pitch, double roll}) _quatToEuler(Quaternion q) {
    final w = q.w, x = q.x, y = q.y, z = q.z;
    final sinrCosp = 2 * (w * x + y * z);
    final cosrCosp = 1 - 2 * (x * x + y * y);
    final roll = math.atan2(sinrCosp, cosrCosp);

    final sinp = 2 * (w * y - z * x);
    final pitch = sinp.abs() >= 1
        ? (math.pi / 2) * sinp.sign
        : math.asin(sinp);

    final sinyCosp = 2 * (w * z + x * y);
    final cosyCosp = 1 - 2 * (y * y + z * z);
    final yaw = math.atan2(sinyCosp, cosyCosp);

    return (yaw: yaw, pitch: pitch, roll: roll);
  }
}
