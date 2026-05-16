import 'package:flutter/material.dart';

/// Small bubble level shown on the capture HUD when the phone is rolled
/// far off horizontal — helps the user keep frames consistent. Hidden when
/// roll is within tolerance.
class BubbleLevel extends StatelessWidget {
  const BubbleLevel({super.key, required this.rollDeg, this.size = 70});

  final double rollDeg;
  final double size;

  bool get _visible => rollDeg.abs() > 6;

  @override
  Widget build(BuildContext context) {
    if (!_visible) return SizedBox(width: size, height: size);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _BubblePainter(rollDeg)),
    );
  }
}

class _BubblePainter extends CustomPainter {
  _BubblePainter(this.rollDeg);
  final double rollDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawCircle(centre, radius, ring);

    // Bubble offset — proportional to roll, capped.
    final clamped = rollDeg.clamp(-30.0, 30.0);
    final dx = (clamped / 30) * (radius - 8);
    final bubble = Paint()..color = Colors.amberAccent;
    canvas.drawCircle(centre + Offset(dx, 0), 6, bubble);

    // Centre tick marks.
    final tick = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    canvas.drawLine(
        centre + const Offset(-3, 0), centre + const Offset(3, 0), tick);
  }

  @override
  bool shouldRepaint(_BubblePainter old) => old.rollDeg != rollDeg;
}
