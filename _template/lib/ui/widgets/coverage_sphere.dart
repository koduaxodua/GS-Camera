import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/coverage_map.dart';

/// Mini-globe overlay showing which directions have been captured.
/// Drawn as a 2D equirectangular projection (cheaper than a real sphere
/// and easier to read in a corner of the screen).
class CoverageSphereWidget extends StatelessWidget {
  const CoverageSphereWidget({
    super.key,
    required this.map,
    required this.azimuthDeg,
    required this.elevationDeg,
    this.size = 120,
  });

  final CoverageMap map;
  final double azimuthDeg;
  final double elevationDeg;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CoveragePainter(
          map: map,
          azimuthDeg: azimuthDeg,
          elevationDeg: elevationDeg,
        ),
      ),
    );
  }
}

class _CoveragePainter extends CustomPainter {
  _CoveragePainter({
    required this.map,
    required this.azimuthDeg,
    required this.elevationDeg,
  });

  final CoverageMap map;
  final double azimuthDeg;
  final double elevationDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final radius = math.min(size.width, size.height) / 2;
    final centre = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(centre, radius, bg);

    // Project (az, el) onto the disc as a polar plot:
    //   azimuth -> angle around centre
    //   elevation -> radial distance (90° = centre, -90° = edge)
    final bins = map.binsSnapshot;
    if (bins.isEmpty) return;
    final eN = bins.length;
    final aN = bins.first.length;

    for (var ei = 0; ei < eN; ei++) {
      for (var ai = 0; ai < aN; ai++) {
        final shots = bins[ei][ai];
        if (shots == 0) continue;
        final el = (ei + 0.5) / eN * 180.0 - 90.0;
        final az = (ai + 0.5) / aN * 360.0;
        final r = (1 - (el + 90) / 180) * radius;
        final theta = az * math.pi / 180;
        final p = centre + Offset(math.sin(theta) * r, -math.cos(theta) * r);

        final paint = Paint()
          ..color = shots >= 3
              ? Colors.greenAccent
              : (shots == 2
                  ? Colors.lightGreen.withValues(alpha: 0.85)
                  : Colors.amber.withValues(alpha: 0.75))
          ..style = PaintingStyle.fill;
        canvas.drawCircle(p, 2.5, paint);
      }
    }

    // Crosshair at current orientation.
    final el = elevationDeg.clamp(-90.0, 90.0);
    final r = (1 - (el + 90) / 180) * radius;
    final theta = azimuthDeg * math.pi / 180;
    final p = centre + Offset(math.sin(theta) * r, -math.cos(theta) * r);
    final ring = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(p, 6, ring);

    // Outer ring.
    final outer = Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(centre, radius - 1, outer);
  }

  @override
  bool shouldRepaint(_CoveragePainter old) => true;
}
