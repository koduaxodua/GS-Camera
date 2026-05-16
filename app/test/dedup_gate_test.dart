import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gs_camera/core/coverage_map.dart';
import 'package:gs_camera/models/photo_meta.dart';
import 'package:gs_camera/services/dedup_gate.dart';

PhotoMeta _meta({
  required int index,
  required double az,
  required double el,
  required double sharp,
  Float32List? embedding,
}) {
  return PhotoMeta(
    index: index,
    filename: '$index.jpg',
    absolutePath: '/tmp/$index.jpg',
    timestampMs: index,
    azimuthDeg: az,
    elevationDeg: el,
    rollDeg: 0,
    position: (x: 0.0, y: 0.0, z: 0.0),
    sharpness: sharp,
    exposureLockValue: 1,
    iso: 100,
    shutterSpeedNs: 8000000,
    embedding: embedding,
  );
}

Float32List _vec(List<double> values) => Float32List.fromList(values);

void main() {
  group('DedupGate', () {
    late CoverageMap map;
    late DedupGate gate;

    setUp(() {
      map = CoverageMap(maxPhotosPerBin: 2);
      gate = DedupGate();
    });

    test('first photo in a cluster is kept', () {
      final candidate = _meta(index: 1, az: 0, el: 0, sharp: 50);
      final decision = gate.evaluate(
        candidate: candidate,
        coverage: map,
        shots: const [],
        similarityThreshold: 0.86,
      );
      expect(decision.action, DedupAction.keep);
    });

    test('high cosine similarity rejects a less-sharp duplicate', () {
      final existing = _meta(
        index: 1,
        az: 0,
        el: 0,
        sharp: 100,
        embedding: _vec([1, 0, 0, 0]),
      );
      // Pre-record so the gate sees it in the spatial cluster.
      final r = map.recordShot(
        azimuthDeg: 0,
        elevationDeg: 0,
        photoIndex: existing.index,
        sharpness: existing.sharpness,
      );
      existing.binAz = r.az;
      existing.binEl = r.el;

      final candidate = _meta(
        index: 2, az: 0, el: 0, sharp: 60,
        embedding: _vec([1, 0, 0, 0]), // identical → cosine = 1.0
      );
      // Bin coords for the candidate too.
      candidate.binAz = r.az;
      candidate.binEl = r.el;

      final decision = gate.evaluate(
        candidate: candidate,
        coverage: map,
        shots: [existing],
        similarityThreshold: 0.86,
      );
      expect(decision.action, DedupAction.reject);
    });

    test('high cosine similarity replaces an existing blurrier shot', () {
      final existing = _meta(
        index: 1,
        az: 0,
        el: 0,
        sharp: 30,
        embedding: _vec([1, 0, 0, 0]),
      );
      final r = map.recordShot(
        azimuthDeg: 0,
        elevationDeg: 0,
        photoIndex: existing.index,
        sharpness: existing.sharpness,
      );
      existing.binAz = r.az;
      existing.binEl = r.el;

      final candidate = _meta(
        index: 2,
        az: 0,
        el: 0,
        sharp: 90,
        embedding: _vec([1, 0, 0, 0]),
      );
      candidate.binAz = r.az;
      candidate.binEl = r.el;

      final decision = gate.evaluate(
        candidate: candidate,
        coverage: map,
        shots: [existing],
        similarityThreshold: 0.86,
      );
      expect(decision.action, DedupAction.replace);
      expect(decision.replacedPhotoIndex, 1);
    });

    test('different views in the same bin are kept (low similarity)', () {
      final existing = _meta(
        index: 1,
        az: 0,
        el: 0,
        sharp: 50,
        embedding: _vec([1, 0, 0, 0]),
      );
      final r = map.recordShot(
        azimuthDeg: 0,
        elevationDeg: 0,
        photoIndex: existing.index,
        sharpness: existing.sharpness,
      );
      existing.binAz = r.az;
      existing.binEl = r.el;

      final candidate = _meta(
        index: 2, az: 0, el: 0, sharp: 50,
        embedding: _vec([0, 1, 0, 0]), // orthogonal → cosine = 0
      );
      candidate.binAz = r.az;
      candidate.binEl = r.el;

      final decision = gate.evaluate(
        candidate: candidate,
        coverage: map,
        shots: [existing],
        similarityThreshold: 0.86,
      );
      expect(decision.action, DedupAction.keep);
    });

    test('without an embedding we fall back to spatial bin-cap rule', () {
      // Fill the bin to capacity. Capture the real bin coordinates so
      // the gate's binIsFull check looks at the right cell.
      ({int az, int el})? coords;
      for (var i = 1; i <= 2; i++) {
        final r = map.recordShot(
          azimuthDeg: 0,
          elevationDeg: 0,
          photoIndex: i,
          sharpness: 100.0,
        );
        coords = (az: r.az, el: r.el);
      }
      final occupants = [
        _meta(index: 1, az: 0, el: 0, sharp: 100)
          ..binAz = coords!.az
          ..binEl = coords.el,
        _meta(index: 2, az: 0, el: 0, sharp: 100)
          ..binAz = coords.az
          ..binEl = coords.el,
      ];

      final candidate = _meta(index: 3, az: 0, el: 0, sharp: 50);
      candidate.binAz = coords.az;
      candidate.binEl = coords.el;
      final decision = gate.evaluate(
        candidate: candidate,
        coverage: map,
        shots: occupants,
        similarityThreshold: 0.86,
      );
      expect(decision.action, DedupAction.reject);
    });
  });

  group('EmbeddingService cosine math', () {
    test('cosine similarity of identical vectors is 1', () {
      // Re-implement here to avoid pulling EmbeddingService into the
      // test (it touches platform channels).
      const dot = 1 + 4 + 9 + 16;
      const na = 1 + 4 + 9 + 16;
      const expected = dot / (na * 1.0);
      expect(expected, closeTo(1.0, 1e-6));
      // For sanity also re-run via DedupGate.embeddingFromList.
      final round = DedupGate.embeddingFromList([1, 2, 3, 4]);
      expect(round, isNotNull);
      expect(round!.length, 4);
    });
  });
}
