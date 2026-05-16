import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/coverage_tracker.dart';
import '../../core/app_strings.dart';

class CoverageRing extends StatelessWidget {
  const CoverageRing({
    super.key,
    required this.state,
    required this.currentYawDeg,
    required this.showRoomBands,
    this.radius = 70,
    this.strokeWidth = 12,
  });

  final CoverageState state;
  final double currentYawDeg;
  final bool showRoomBands;
  final double radius;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final size = (radius + strokeWidth + 18) * 2;
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black38,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _CoverageRingPainter(
              bins: state.azimuthBins,
              radius: radius,
              strokeWidth: strokeWidth,
            ),
          ),
          Transform.rotate(
            angle: currentYawDeg * 3.141592653589793 / 180,
            child: Transform.translate(
              offset: Offset(0, -radius),
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Colors.black54, blurRadius: 6),
                  ],
                ),
              ),
            ),
          ),
          if (showRoomBands) ...[
            Positioned(
              top: 6,
              child: _MiniBandProgress(
                icon: Icons.arrow_drop_up,
                label: AppStrings.ceilingLabel,
                percent: state.ceilingPercent,
              ),
            ),
            Positioned(
              bottom: 6,
              child: _MiniBandProgress(
                icon: Icons.arrow_drop_down,
                label: AppStrings.floorLabel,
                percent: state.floorPercent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CoverageRingPainter extends CustomPainter {
  _CoverageRingPainter({
    required this.bins,
    required this.radius,
    required this.strokeWidth,
  });

  final List<CoverageBin> bins;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const total = CoverageTracker.azimuthBins;
    const segment = 2 * math.pi / total;
    for (var i = 0; i < total; i++) {
      final bin =
          i < bins.length ? bins[i] : CoverageTracker.emptyRoomBin(i, 'level');
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = colorFor(bin.color);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2 + i * segment + 0.018,
        segment - 0.036,
        false,
        paint,
      );
    }
  }

  static Color colorFor(CoverageBinColor color) {
    return switch (color) {
      CoverageBinColor.blue => const Color(0xFF42A5F5),
      CoverageBinColor.green => const Color(0xFF4CAF50),
      CoverageBinColor.purple => const Color(0xFFAB47BC),
      CoverageBinColor.orange => const Color(0xFFFF9800),
      CoverageBinColor.red => const Color(0xFFF44336),
      CoverageBinColor.gray => const Color(0xFF9E9E9E),
    };
  }

  @override
  bool shouldRepaint(covariant _CoverageRingPainter oldDelegate) {
    return oldDelegate.bins != bins ||
        oldDelegate.radius != radius ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _MiniBandProgress extends StatelessWidget {
  const _MiniBandProgress({
    required this.icon,
    required this.label,
    required this.percent,
  });

  final IconData icon;
  final String label;
  final double percent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white, size: 18),
        Text(
          '$label: ${percent.round()}%',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
