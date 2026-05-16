import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// One photo as it lives inside a coverage bin: just enough to make
/// dedup + best-of-K decisions without dragging the full PhotoMeta in.
class BinPhoto {
  BinPhoto({
    required this.photoIndex,
    required this.sharpness,
  });
  final int photoIndex;
  double sharpness;
}

/// Hint that goes alongside the suggested next direction so the prompt
/// widget can phrase the cue naturally ("look up at the ceiling" vs.
/// "spin behind you").
enum NextDirectionKind {
  none, // everything is covered
  pan, // yaw delta — turn left/right
  tiltUp, // missing in the upper hemisphere
  tiltDown, // missing in the lower hemisphere
  combined, // a diagonal direction
}

class NextDirection {
  NextDirection({
    required this.dir,
    required this.kind,
    required this.azimuthDeg,
    required this.elevationDeg,
  });
  final Vector3 dir;
  final NextDirectionKind kind;
  final double azimuthDeg;
  final double elevationDeg;
}

/// Tracks how thoroughly the user has captured the surrounding sphere
/// AND which photo we're keeping per bin.
///
/// The sphere is divided into bins along (azimuth, elevation). Each bin
/// keeps up to [maxPhotosPerBin] [BinPhoto]s, ordered with the sharpest
/// last so we can always check `last` for the "best in bin".
class CoverageMap {
  CoverageMap({
    this.azimuthBins = 36,
    this.elevationBins = 12,
    this.maxPhotosPerBin = 2,
  }) : _bins = List.generate(
          elevationBins,
          (_) => List.generate(
            azimuthBins,
            (_) => <BinPhoto>[],
            growable: false,
          ),
          growable: false,
        );

  /// Divides 360° into N azimuth columns. 36 = one bin per 10°.
  final int azimuthBins;

  /// Divides -90° to +90° into N elevation rows. 12 = one bin per 15°.
  final int elevationBins;

  /// Cap on how many photos we keep per bin. Two is the sweet spot —
  /// one straight-on shot and (optionally) one stepped-closer detail.
  final int maxPhotosPerBin;

  final List<List<List<BinPhoto>>> _bins;

  int _accepted = 0;
  int get acceptedCount => _accepted;

  /// Record a successfully captured frame at the given orientation.
  /// Returns the (azimuthBin, elevationBin) coordinates that were used,
  /// which the dedup gate caches on the [PhotoMeta] so we can later
  /// drop the photo from the same bin without scanning again.
  ///
  /// Also returns [evicted] — the photo index, if any, that fell off
  /// the end of the bin because it was over [maxPhotosPerBin]. The
  /// caller is expected to mark that PhotoMeta as discarded and delete
  /// its file. (Without this, bins grew unbounded — a v0.2 bug.)
  ({int az, int el, int? evicted}) recordShot({
    required double azimuthDeg,
    required double elevationDeg,
    required int photoIndex,
    required double sharpness,
  }) {
    final (a, e) = _binIndex(azimuthDeg, elevationDeg);
    final bin = _bins[e][a];
    bin.add(BinPhoto(photoIndex: photoIndex, sharpness: sharpness));
    // Sort ascending so bin[0] is the WORST shot.
    bin.sort((x, y) => x.sharpness.compareTo(y.sharpness));
    int? evicted;
    if (bin.length > maxPhotosPerBin) {
      evicted = bin.removeAt(0).photoIndex;
    }
    _accepted++;
    return (az: a, el: e, evicted: evicted);
  }

  /// Drop a previously-recorded photo (by its index) when the dedup gate
  /// decides to replace it. Quiet no-op if it isn't in the expected bin.
  void removeShot({
    required int azimuthBin,
    required int elevationBin,
    required int photoIndex,
  }) {
    if (azimuthBin < 0 || elevationBin < 0) return;
    if (elevationBin >= elevationBins) return;
    if (azimuthBin >= azimuthBins) return;
    final bin = _bins[elevationBin][azimuthBin];
    final removed = bin.length;
    bin.removeWhere((p) => p.photoIndex == photoIndex);
    final after = bin.length;
    if (after < removed) _accepted -= (removed - after);
  }

  /// Photos currently kept in the bin pointed to by the orientation.
  List<BinPhoto> photosAt(double azimuthDeg, double elevationDeg) {
    final (a, e) = _binIndex(azimuthDeg, elevationDeg);
    return List<BinPhoto>.unmodifiable(_bins[e][a]);
  }

  /// Photos in `bin` and its 8 neighbours, useful for dedup similarity
  /// checks against the local cluster.
  Iterable<BinPhoto> photosNear(double azimuthDeg, double elevationDeg) sync* {
    final (a, e) = _binIndex(azimuthDeg, elevationDeg);
    for (var de = -1; de <= 1; de++) {
      final ne = e + de;
      if (ne < 0 || ne >= elevationBins) continue;
      for (var da = -1; da <= 1; da++) {
        final na = (a + da + azimuthBins) % azimuthBins;
        yield* _bins[ne][na];
      }
    }
  }

  /// True if the spatial cluster around the current orientation already
  /// holds enough shots that further captures would just be duplicates.
  bool clusterIsFull(double azimuthDeg, double elevationDeg) {
    final near = photosNear(azimuthDeg, elevationDeg).length;
    return near >= maxPhotosPerBin * 2;
  }

  /// Cap on bin capacity — exposed so the dedup gate can decide whether
  /// to evict-and-replace or just reject a candidate.
  bool binIsFull(int az, int el) => _bins[el][az].length >= maxPhotosPerBin;

  (int, int) _binIndex(double az, double el) {
    final azNorm = ((az % 360) + 360) % 360;
    final aIdx = ((azNorm / 360) * azimuthBins).floor() % azimuthBins;
    final elClamped = el.clamp(-89.999, 89.999);
    final eIdx = (((elClamped + 90) / 180) * elevationBins)
        .floor()
        .clamp(0, elevationBins - 1);
    return (aIdx, eIdx);
  }

  /// Inclusive elevation row range we count as "useful" for indoor
  /// scanning — we ignore the bin directly below our feet and the bin
  /// directly above our head because nobody captures those usefully
  /// while walking.
  (int, int) _usefulElevationRange() {
    final eStart = (elevationBins * 0.16).floor();
    final eEnd = (elevationBins * 0.92).ceil();
    return (eStart, eEnd);
  }

  /// Strict coverage fraction — fraction of useful bins that have at
  /// least [minShots] photo of their own. This is the number we use to
  /// gate the Finish button: we don't want the user to think they're
  /// done because of generous neighbour smoothing.
  double coverageFractionStrict({int minShots = 1}) {
    final (eStart, eEnd) = _usefulElevationRange();
    var total = 0;
    var covered = 0;
    for (var e = eStart; e < eEnd; e++) {
      for (var a = 0; a < azimuthBins; a++) {
        total++;
        if (_bins[e][a].length >= minShots) covered++;
      }
    }
    return total == 0 ? 0.0 : covered / total;
  }

  /// Smoothed coverage fraction — counts an empty bin as covered if at
  /// least two of its immediate neighbours have captures. Used for the
  /// HUD progress display because it's more forgiving of gyro drift
  /// between adjacent bins.
  double coverageFractionSmoothed({int minShots = 1}) {
    final (eStart, eEnd) = _usefulElevationRange();
    var total = 0;
    var covered = 0;
    for (var e = eStart; e < eEnd; e++) {
      for (var a = 0; a < azimuthBins; a++) {
        total++;
        if (_isCellCovered(a, e, minShots)) covered++;
      }
    }
    return total == 0 ? 0.0 : covered / total;
  }

  /// Backwards-compatible default — keeps callers that don't care about
  /// the strict/smoothed distinction working.
  double coverageFraction({int minShots = 1}) =>
      coverageFractionSmoothed(minShots: minShots);

  bool _isCellCovered(int a, int e, int minShots) {
    if (_bins[e][a].length >= minShots) return true;
    var neighbours = 0;
    for (final (da, de) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      final na = (a + da + azimuthBins) % azimuthBins;
      final ne = e + de;
      if (ne < 0 || ne >= elevationBins) continue;
      if (_bins[ne][na].isNotEmpty) neighbours++;
    }
    return neighbours >= 2;
  }

  /// Per-azimuth fill — used by the horizon ring widget. Returns the
  /// max bin count across the useful elevation range for each azimuth
  /// column, normalized into 0..1.
  List<double> azimuthCoverage() {
    final (eStart, eEnd) = _usefulElevationRange();
    final out = List<double>.filled(azimuthBins, 0);
    for (var a = 0; a < azimuthBins; a++) {
      var best = 0;
      for (var e = eStart; e < eEnd; e++) {
        if (_bins[e][a].length > best) best = _bins[e][a].length;
      }
      out[a] = (best / maxPhotosPerBin).clamp(0.0, 1.0);
    }
    return out;
  }

  /// Locate the largest contiguous coverage gap and describe it as a
  /// direction-with-intent so the prompt widget can speak naturally.
  /// Returns null when nothing meaningful is missing.
  NextDirection? suggestNextDirection() {
    final (eStart, eEnd) = _usefulElevationRange();
    int? bestA;
    int? bestE;
    var maxGap = 0;
    for (var e = eStart; e < eEnd; e++) {
      for (var a = 0; a < azimuthBins; a++) {
        if (_bins[e][a].isEmpty) {
          var score = 1;
          for (final (da, de) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
            final na = (a + da + azimuthBins) % azimuthBins;
            final ne = e + de;
            if (ne < 0 || ne >= elevationBins) continue;
            if (_bins[ne][na].isEmpty) score++;
          }
          if (score > maxGap) {
            maxGap = score;
            bestA = a;
            bestE = e;
          }
        }
      }
    }
    if (bestA == null) return null;

    final az = (bestA + 0.5) / azimuthBins * 360.0;
    final el = (bestE! + 0.5) / elevationBins * 180.0 - 90.0;
    final azRad = az * math.pi / 180;
    final elRad = el * math.pi / 180;
    final dir = Vector3(
      math.cos(elRad) * math.sin(azRad),
      math.sin(elRad),
      math.cos(elRad) * math.cos(azRad),
    );

    final NextDirectionKind kind;
    if (el > 25) {
      kind = NextDirectionKind.tiltUp;
    } else if (el < -25) {
      kind = NextDirectionKind.tiltDown;
    } else if (el.abs() < 8) {
      kind = NextDirectionKind.pan;
    } else {
      kind = NextDirectionKind.combined;
    }
    return NextDirection(
      dir: dir,
      kind: kind,
      azimuthDeg: az,
      elevationDeg: el,
    );
  }

  /// Snapshot of per-bin counts for the legacy polar widget. Outer list
  /// = elevation rows, inner = azimuth columns.
  List<List<int>> get binsSnapshot => _bins
      .map((row) =>
          List<int>.unmodifiable(row.map((bin) => bin.length).toList()))
      .toList(growable: false);
}
