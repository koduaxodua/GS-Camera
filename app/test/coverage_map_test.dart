import 'package:flutter_test/flutter_test.dart';
import 'package:gs_camera/core/coverage_map.dart';

void main() {
  group('CoverageMap', () {
    test('records shots and assigns bin coordinates', () {
      final map = CoverageMap();
      final r = map.recordShot(
        azimuthDeg: 45,
        elevationDeg: 0,
        photoIndex: 1,
        sharpness: 50,
      );
      expect(r.az, greaterThanOrEqualTo(0));
      expect(r.el, greaterThanOrEqualTo(0));
      expect(r.evicted, isNull);
      expect(map.acceptedCount, 1);
    });

    test('trims to maxPhotosPerBin and reports the eviction', () {
      final map = CoverageMap(maxPhotosPerBin: 2);
      // Three photos in the SAME bin (same az/el).
      final a = map.recordShot(
          azimuthDeg: 10, elevationDeg: 5, photoIndex: 1, sharpness: 10);
      final b = map.recordShot(
          azimuthDeg: 10, elevationDeg: 5, photoIndex: 2, sharpness: 30);
      final c = map.recordShot(
          azimuthDeg: 10, elevationDeg: 5, photoIndex: 3, sharpness: 50);
      expect(a.evicted, isNull);
      expect(b.evicted, isNull);
      // Photo 1 (sharpness 10) was the worst so it falls off when the
      // third arrives.
      expect(c.evicted, 1);
      // Only the two best stay.
      final stillThere = map.photosAt(10, 5).map((p) => p.photoIndex).toList()
        ..sort();
      expect(stillThere, [2, 3]);
    });

    test('removeShot is a no-op when the photo is not in the bin', () {
      final map = CoverageMap();
      map.recordShot(
          azimuthDeg: 0, elevationDeg: 0, photoIndex: 1, sharpness: 50);
      map.removeShot(azimuthBin: 0, elevationBin: 5, photoIndex: 999);
      expect(map.acceptedCount, 1);
    });

    test('removeShot decrements the accepted counter (v0.2 regression)', () {
      final map = CoverageMap();
      final r = map.recordShot(
          azimuthDeg: 0, elevationDeg: 0, photoIndex: 1, sharpness: 50);
      map.removeShot(azimuthBin: r.az, elevationBin: r.el, photoIndex: 1);
      expect(map.acceptedCount, 0);
    });

    test('strict coverage requires per-bin photos; smoothed forgives drift',
        () {
      final map = CoverageMap();
      // Drop a single shot directly between two empty cells. Smoothed
      // coverage will fill the empty neighbour because it has two
      // occupied neighbours; strict will not.
      map.recordShot(
          azimuthDeg: 0, elevationDeg: 0, photoIndex: 1, sharpness: 50);
      map.recordShot(
          azimuthDeg: 30, elevationDeg: 0, photoIndex: 2, sharpness: 50);
      map.recordShot(
          azimuthDeg: 0, elevationDeg: 30, photoIndex: 3, sharpness: 50);
      map.recordShot(
          azimuthDeg: 0, elevationDeg: -30, photoIndex: 4, sharpness: 50);
      expect(map.coverageFractionStrict(),
          lessThan(map.coverageFractionSmoothed()));
    });

    test('clusterIsFull respects spatial cap', () {
      final map = CoverageMap(maxPhotosPerBin: 2);
      // Pile up four photos in adjacent bins — clusterIsFull is
      // maxPhotosPerBin * 2 = 4, so the fifth should report full.
      for (var i = 1; i <= 4; i++) {
        map.recordShot(
          azimuthDeg: 5.0 * i,
          elevationDeg: 0,
          photoIndex: i,
          sharpness: 10.0 * i,
        );
      }
      expect(map.clusterIsFull(10, 0), isTrue);
    });

    test('suggestNextDirection returns null when fully covered', () {
      final map =
          CoverageMap(azimuthBins: 2, elevationBins: 2, maxPhotosPerBin: 1);
      // Cover the four useful bins; with the very-bottom row excluded
      // by the heuristic the useful bins might be fewer, so just fill
      // every bin.
      map.recordShot(
          azimuthDeg: 0, elevationDeg: -45, photoIndex: 1, sharpness: 50);
      map.recordShot(
          azimuthDeg: 180, elevationDeg: -45, photoIndex: 2, sharpness: 50);
      map.recordShot(
          azimuthDeg: 0, elevationDeg: 45, photoIndex: 3, sharpness: 50);
      map.recordShot(
          azimuthDeg: 180, elevationDeg: 45, photoIndex: 4, sharpness: 50);
      expect(map.suggestNextDirection(), isNull);
    });
  });
}
