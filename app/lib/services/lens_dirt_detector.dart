import 'dart:math' as math;
import 'dart:typed_data';

/// Detects the soft, low-contrast circular hazes that smudges and
/// fingerprints leave on a phone lens.
///
/// The signature: smudges blur high-frequency detail in a localised
/// region. We split the frame into tiles and flag tiles whose Sobel
/// magnitude is far below the frame median *and* whose mean luminance
/// is unusually high (smudges scatter light).
///
/// Heavy enough that we only run it during pre-flight, on 1-2 reference
/// frames before the user starts capturing.
class LensDirtDetector {
  static const _tileSize = 32;

  /// Returns a confidence score in 0..1. Above 0.4 we surface the
  /// "wipe your lens" prompt.
  static double scoreSmudges(Uint8List luma, int width, int height) {
    if (width < _tileSize * 4 || height < _tileSize * 4) return 0;
    final tilesX = width ~/ _tileSize;
    final tilesY = height ~/ _tileSize;
    final tileScores = <double>[];
    final tileMeans = <double>[];

    for (var ty = 0; ty < tilesY; ty++) {
      for (var tx = 0; tx < tilesX; tx++) {
        final sx = tx * _tileSize;
        final sy = ty * _tileSize;
        final (mag, mean) = _tileStats(luma, width, height, sx, sy, _tileSize);
        tileScores.add(mag);
        tileMeans.add(mean);
      }
    }
    if (tileScores.isEmpty) return 0;

    final sortedScores = [...tileScores]..sort();
    final medianMag = sortedScores[sortedScores.length ~/ 2];

    final sortedMeans = [...tileMeans]..sort();
    final medianMean = sortedMeans[sortedMeans.length ~/ 2];

    var suspectTiles = 0;
    for (var i = 0; i < tileScores.length; i++) {
      final lowDetail = tileScores[i] < medianMag * 0.35;
      final brighterThanFrame = tileMeans[i] > medianMean * 1.10;
      if (lowDetail && brighterThanFrame) suspectTiles++;
    }
    final fraction = suspectTiles / tileScores.length;
    // Map fraction to a softened score; saturate at 0.20 of frame.
    return math.min(1.0, fraction / 0.20);
  }

  static (double mag, double mean) _tileStats(
    Uint8List luma,
    int width,
    int height,
    int sx,
    int sy,
    int size,
  ) {
    var sumMag = 0.0;
    var sumLuma = 0;
    var n = 0;
    for (var y = sy + 1; y < sy + size - 1 && y < height - 1; y++) {
      for (var x = sx + 1; x < sx + size - 1 && x < width - 1; x++) {
        final c = luma[y * width + x];
        sumLuma += c;
        // Sobel-X
        final gx = -luma[(y - 1) * width + (x - 1)] +
            luma[(y - 1) * width + (x + 1)] -
            2 * luma[y * width + (x - 1)] +
            2 * luma[y * width + (x + 1)] -
            luma[(y + 1) * width + (x - 1)] +
            luma[(y + 1) * width + (x + 1)];
        // Sobel-Y
        final gy = -luma[(y - 1) * width + (x - 1)] -
            2 * luma[(y - 1) * width + x] -
            luma[(y - 1) * width + (x + 1)] +
            luma[(y + 1) * width + (x - 1)] +
            2 * luma[(y + 1) * width + x] +
            luma[(y + 1) * width + (x + 1)];
        sumMag += math.sqrt((gx * gx + gy * gy).toDouble());
        n++;
      }
    }
    if (n == 0) return (0, 0);
    return (sumMag / n, sumLuma / n);
  }
}
