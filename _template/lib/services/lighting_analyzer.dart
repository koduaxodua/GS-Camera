import 'dart:typed_data';

class LightingReport {
  LightingReport({
    required this.meanLuminance,
    required this.clippedFraction,
    required this.darkFraction,
  });

  final double meanLuminance;     // 0..255
  final double clippedFraction;    // 0..1
  final double darkFraction;       // 0..1

  /// True if the room is too dark to capture without raising ISO past
  /// the safe threshold. UI should suggest "add light".
  bool get tooDark => meanLuminance < 60;

  /// True if more than 5% of pixels are clipped to white — usually a
  /// direct light source pointed at the camera.
  bool get clippingExcess => clippedFraction > 0.05;

  /// True if the histogram is bimodal-extreme: lots of pure black and lots
  /// of pure white. Causes WB and AE drift between adjacent frames.
  bool get highDynamicRange => clippedFraction > 0.02 && darkFraction > 0.20;
}

class LightingAnalyzer {
  /// Analyse a single grayscale plane (Y from YUV420, typically 320×240).
  static LightingReport analyse(Uint8List luma) {
    if (luma.isEmpty) {
      return LightingReport(meanLuminance: 0, clippedFraction: 0, darkFraction: 0);
    }
    var sum = 0;
    var clipped = 0;
    var dark = 0;
    for (final v in luma) {
      sum += v;
      if (v >= 250) clipped++;
      if (v <= 10) dark++;
    }
    final n = luma.length;
    return LightingReport(
      meanLuminance: sum / n,
      clippedFraction: clipped / n,
      darkFraction: dark / n,
    );
  }
}
