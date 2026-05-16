import 'dart:typed_data';

/// Cheap on-device sharpness scoring using the variance-of-Laplacian method.
///
/// Higher score = sharper image. Threshold for "acceptable" is tuned per ISO
/// — noisy frames have higher baseline Laplacian energy from sensor noise,
/// so we raise the bar. Operate on a downscaled grayscale to stay fast
/// (sub-10 ms on a 320×240 plane).
class BlurDetector {
  /// Compute Laplacian variance on a single-channel grayscale plane.
  ///
  /// [pixels] must be `width * height` bytes long (Y plane from YUV420 or
  /// converted RGB → luma). The kernel used is the standard 3×3 Laplacian:
  ///
  ///        0  1  0
  ///        1 -4  1
  ///        0  1  0
  static double laplacianVariance(Uint8List pixels, int width, int height) {
    if (width < 3 || height < 3) return 0;
    final stride = width;
    var sum = 0.0;
    var sumSq = 0.0;
    var n = 0;

    for (var y = 1; y < height - 1; y++) {
      final rowM = (y - 1) * stride;
      final row = y * stride;
      final rowP = (y + 1) * stride;
      for (var x = 1; x < width - 1; x++) {
        final c = pixels[row + x];
        final l = pixels[row + x - 1];
        final r = pixels[row + x + 1];
        final u = pixels[rowM + x];
        final d = pixels[rowP + x];
        final lap = (l + r + u + d) - 4 * c;
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 0;
    final mean = sum / n;
    return (sumSq / n) - (mean * mean);
  }

  /// Sharpness threshold tuned per ISO. Above this score the frame passes.
  ///
  /// Calibrated against handheld phone test shots — values may need a
  /// per-device tweak after field testing.
  static double thresholdForIso(int iso) {
    // Baseline 30 at ISO 100, scaling up modestly with sensor noise.
    if (iso <= 100) return 30;
    if (iso <= 400) return 45;
    if (iso <= 800) return 70;
    if (iso <= 1600) return 110;
    return 160;
  }
}
