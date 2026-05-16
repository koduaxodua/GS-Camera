import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Tracks how thoroughly the user has captured the surrounding sphere.
///
/// The sphere is divided into bins along (azimuth, elevation). We use a
/// simple regular grid rather than an icosphere for cheaper lookups and
/// because postshot doesn't care about exact uniformity — what matters is
/// "did the user cover the major directions".
class CoverageMap {
  CoverageMap({this.azimuthBins = 36, this.elevationBins = 12})
      : _bins = List.generate(
          elevationBins,
          (_) => List<int>.filled(azimuthBins, 0, growable: false),
          growable: false,
        );

  /// Divides 360° into N azimuth columns. 36 = one bin per 10°.
  final int azimuthBins;

  /// Divides -90° to +90° into N elevation rows. 12 = one bin per 15°.
  final int elevationBins;

  final List<List<int>> _bins;

  int _accepted = 0;
  int get acceptedCount => _accepted;

  /// Record a successfully captured frame at the given orientation.
  void recordShot({required double azimuthDeg, required double elevationDeg}) {
    final (a, e) = _binIndex(azimuthDeg, elevationDeg);
    _bins[e][a]++;
    _accepted++;
  }

  /// Number of shots in the bin pointed to by current orientation.
  int shotsAt(double azimuthDeg, double elevationDeg) {
    final (a, e) = _binIndex(azimuthDeg, elevationDeg);
    return _bins[e][a];
  }

  (int, int) _binIndex(double az, double el) {
    final azNorm = ((az % 360) + 360) % 360;
    final aIdx = ((azNorm / 360) * azimuthBins).floor() % azimuthBins;
    final elClamped = el.clamp(-89.999, 89.999);
    final eIdx = (((elClamped + 90) / 180) * elevationBins).floor()
        .clamp(0, elevationBins - 1);
    return (aIdx, eIdx);
  }

  /// Fraction of bins (in the "useful" elevation range) that have at least
  /// `minShots` captures. The very-bottom and very-top rows are excluded —
  /// the floor under your feet and the ceiling directly overhead are not
  /// useful for interior reconstruction.
  double coverageFraction({int minShots = 1}) {
    final eStart = (elevationBins * 0.16).floor();
    final eEnd = (elevationBins * 0.92).ceil();
    var total = 0;
    var covered = 0;
    for (var e = eStart; e < eEnd; e++) {
      for (var a = 0; a < azimuthBins; a++) {
        total++;
        if (_bins[e][a] >= minShots) covered++;
      }
    }
    return total == 0 ? 0.0 : covered / total;
  }

  /// Locates the centre of the largest contiguous gap in coverage and
  /// returns the direction to point the user toward, or null if everything
  /// is well covered.
  Vector3? suggestNextDirection() {
    int? bestAz;
    int? bestEl;
    var maxGap = 0;

    final eStart = (elevationBins * 0.16).floor();
    final eEnd = (elevationBins * 0.92).ceil();

    for (var e = eStart; e < eEnd; e++) {
      for (var a = 0; a < azimuthBins; a++) {
        if (_bins[e][a] == 0) {
          // Score gap by neighbour emptiness.
          var score = 1;
          for (final (da, de) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
            final na = (a + da) % azimuthBins;
            final ne = e + de;
            if (ne < 0 || ne >= elevationBins) continue;
            if (_bins[ne][na] == 0) score++;
          }
          if (score > maxGap) {
            maxGap = score;
            bestAz = a;
            bestEl = e;
          }
        }
      }
    }
    if (bestAz == null) return null;
    final az = (bestAz + 0.5) / azimuthBins * 360.0;
    final el = (bestEl! + 0.5) / elevationBins * 180.0 - 90.0;
    final azRad = az * math.pi / 180;
    final elRad = el * math.pi / 180;
    return Vector3(
      math.cos(elRad) * math.sin(azRad),
      math.sin(elRad),
      math.cos(elRad) * math.cos(azRad),
    );
  }

  /// Snapshot of bin counts for rendering. Outer list = elevation rows,
  /// inner list = azimuth columns. Returned as an unmodifiable view.
  List<List<int>> get binsSnapshot =>
      _bins.map((row) => List<int>.unmodifiable(row)).toList(growable: false);
}
