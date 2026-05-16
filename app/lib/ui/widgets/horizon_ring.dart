import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Compact horizontal bar with one wedge per azimuth bin. Wedge fill goes
/// red → amber → green as that azimuth column gets covered. The "where
/// am I pointing" cursor overlays as a thin white tick so the user can
/// orient at a glance.
class HorizonRing extends StatelessWidget {
  const HorizonRing({
    super.key,
    required this.azimuthCoverage,
    required this.currentAzimuthDeg,
    this.height = 18,
  });

  /// One value per azimuth bin in 0..1.
  final List<double> azimuthCoverage;

  /// Where the camera is pointing right now, used to draw the cursor.
  final double currentAzimuthDeg;

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _HorizonPainter(
          azimuthCoverage: azimuthCoverage,
          currentAzimuthDeg: currentAzimuthDeg,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _HorizonPainter extends CustomPainter {
  _HorizonPainter({
    required this.azimuthCoverage,
    required this.currentAzimuthDeg,
  });

  final List<double> azimuthCoverage;
  final double currentAzimuthDeg;

  @override
  void paint(Canvas canvas, Size size) {
    if (azimuthCoverage.isEmpty) return;
    final n = azimuthCoverage.length;
    final wedgeWidth = size.width / n;
    final radius = math.min(size.height / 2, 4.0);

    // Background trough.
    final trough = Paint()..color = Colors.white.withValues(alpha: 0.08);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      trough,
    );

    for (var i = 0; i < n; i++) {
      final fill = azimuthCoverage[i].clamp(0.0, 1.0);
      if (fill <= 0) continue;
      final paint = Paint()..color = _ramp(fill);
      final left = i * wedgeWidth + 1;
      final right = (i + 1) * wedgeWidth - 1;
      final rect = Rect.fromLTRB(left, 4, right, size.height - 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius / 2)),
        paint,
      );
    }

    // Cursor: a thin vertical bar at the current heading.
    final cursorX =
        (((currentAzimuthDeg % 360) + 360) % 360) / 360 * size.width;
    final cursor = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(cursorX, 0),
      Offset(cursorX, size.height),
      cursor,
    );
  }

  static Color _ramp(double t) {
    if (t < 0.5) {
      return Color.lerp(Colors.redAccent, Colors.amberAccent, t * 2)!;
    }
    return Color.lerp(
        Colors.amberAccent, Colors.lightGreenAccent, (t - 0.5) * 2)!;
  }

  @override
  bool shouldRepaint(_HorizonPainter old) => true;
}
