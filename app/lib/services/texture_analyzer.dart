import 'dart:math' as math;
import 'dart:typed_data';

class TextureAnalyzer {
  /// Returns 0.0..1.0 from a luma plane. It combines edge density and local
  /// variance on a cheap 128 px thumbnail-like sampling grid.
  static double score(
    Uint8List luma,
    int width,
    int height, {
    int targetSize = 128,
  }) {
    if (width < 4 || height < 4 || luma.length < width * height) return 0;
    final stepX = math.max(1, width ~/ targetSize);
    final stepY = math.max(1, height ~/ targetSize);
    var samples = 0;
    var edgeHits = 0;
    var varianceSum = 0.0;

    for (var y = stepY; y < height - stepY; y += stepY) {
      for (var x = stepX; x < width - stepX; x += stepX) {
        final c = luma[y * width + x].toDouble();
        final left = luma[y * width + x - stepX].toDouble();
        final right = luma[y * width + x + stepX].toDouble();
        final up = luma[(y - stepY) * width + x].toDouble();
        final down = luma[(y + stepY) * width + x].toDouble();
        final gx = (right - left).abs();
        final gy = (down - up).abs();
        final edge = math.sqrt(gx * gx + gy * gy);
        if (edge > 18) edgeHits++;
        final mean = (c + left + right + up + down) / 5.0;
        varianceSum +=
            ((c - mean).abs() + (left - mean).abs() + (right - mean).abs()) /
                3.0;
        samples++;
      }
    }
    if (samples == 0) return 0;
    final edgeDensity = edgeHits / samples;
    final variance = (varianceSum / samples / 48.0).clamp(0.0, 1.0);
    return (edgeDensity * 0.65 + variance * 0.35).clamp(0.0, 1.0);
  }
}
