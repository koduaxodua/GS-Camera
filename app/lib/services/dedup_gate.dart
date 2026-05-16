import 'dart:typed_data';

import '../core/coverage_map.dart';
import '../models/photo_meta.dart';
import 'embedding_service.dart';

/// What the dedup gate decided to do with a candidate capture.
enum DedupAction { keep, replace, reject }

class DedupDecision {
  DedupDecision._(this.action, [this.replacedPhotoIndex, this.reason]);

  factory DedupDecision.keep(String reason) =>
      DedupDecision._(DedupAction.keep, null, reason);
  factory DedupDecision.replace(int oldIndex, String reason) =>
      DedupDecision._(DedupAction.replace, oldIndex, reason);
  factory DedupDecision.reject(String reason) =>
      DedupDecision._(DedupAction.reject, null, reason);

  final DedupAction action;
  final int? replacedPhotoIndex;
  final String? reason;
}

/// Decides whether a freshly-captured candidate is worth keeping in the
/// session. Looks at both the spatial cluster (the candidate's bin and
/// its 8 neighbours in the coverage map) and the semantic similarity
/// of the on-device embedding vector.
///
/// Pure logic, easy to unit-test — the coordinator is responsible for
/// actually deleting the JPEG and updating the coverage map afterwards.
class DedupGate {
  DedupGate({this.replaceSharpnessMargin = 1.05});

  /// New photo must be at least this much sharper than the duplicate it
  /// would replace (so we don't flap between two equally-blurry frames).
  final double replaceSharpnessMargin;

  DedupDecision evaluate({
    required PhotoMeta candidate,
    required CoverageMap coverage,
    required List<PhotoMeta> shots,
    required double similarityThreshold,
  }) {
    // Without an embedding for the candidate we can still gate on bin
    // capacity — the spatial cap alone gets us most of the way to the
    // 70 % photo reduction goal even on devices where the model failed
    // to load.
    final candidateEmbedding = candidate.embedding;

    // Pull the photos we'd potentially compare against. Look at the
    // candidate's bin + 8 neighbours.
    final near = coverage
        .photosNear(candidate.azimuthDeg, candidate.elevationDeg)
        .toList();

    if (near.isEmpty) {
      return DedupDecision.keep('first photo in cluster');
    }

    int? mostSimilarIndex;
    double bestSim = -1.0;
    double bestSimSharpness = 0.0;
    for (final binPhoto in near) {
      final existing = _photoByIndex(shots, binPhoto.photoIndex);
      if (existing == null) continue;

      double sim = -1.0;
      if (candidateEmbedding != null && existing.embedding != null) {
        sim = EmbeddingService.cosineSimilarity(
          candidateEmbedding,
          existing.embedding!,
        );
      }
      if (sim > bestSim) {
        bestSim = sim;
        mostSimilarIndex = existing.index;
        bestSimSharpness = existing.sharpness;
      }
    }

    final binIsFull = coverage.binIsFull(candidate.binAz, candidate.binEl);
    final threshold = similarityThreshold;

    // Strong duplicate: cosine similarity over threshold means the
    // existing shot covers what we'd be saving.
    if (bestSim >= threshold && mostSimilarIndex != null) {
      if (candidate.sharpness >= bestSimSharpness * replaceSharpnessMargin) {
        return DedupDecision.replace(
          mostSimilarIndex,
          'duplicate (sim=${bestSim.toStringAsFixed(3)}), '
          'new is sharper (${candidate.sharpness.toStringAsFixed(1)} '
          'vs ${bestSimSharpness.toStringAsFixed(1)})',
        );
      }
      return DedupDecision.reject(
        'duplicate (sim=${bestSim.toStringAsFixed(3)}), '
        'new is not sharper',
      );
    }

    // Spatial fallback: bin already at capacity AND new candidate isn't
    // more semantically novel — reject. Without an embedding we keep
    // the strict bin cap as the only signal.
    if (binIsFull) {
      final inBin = coverage
          .photosAt(candidate.azimuthDeg, candidate.elevationDeg)
          .toList();
      // Photos in this bin are sorted ascending by sharpness — the worst
      // is index 0.
      if (inBin.isNotEmpty &&
          candidate.sharpness >
              inBin.first.sharpness * replaceSharpnessMargin) {
        return DedupDecision.replace(
          inBin.first.photoIndex,
          'bin full, candidate sharper than the worst occupant',
        );
      }
      return DedupDecision.reject('bin full, candidate not sharper');
    }

    return DedupDecision.keep(
      candidateEmbedding == null
          ? 'novel pose (no embedding to dedup against)'
          : 'novel pose (sim=${bestSim.toStringAsFixed(3)} below threshold)',
    );
  }

  static PhotoMeta? _photoByIndex(List<PhotoMeta> shots, int index) {
    for (final p in shots) {
      if (p.index == index) return p;
    }
    return null;
  }

  /// Convenience: build a Float32List from a JSON list (for tests / when
  /// rehydrating from a sidecar JSON).
  static Float32List? embeddingFromList(List<dynamic>? raw) {
    if (raw == null || raw.isEmpty) return null;
    final out = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      out[i] = (raw[i] as num).toDouble();
    }
    return out;
  }
}
