import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/coverage_map.dart';

/// Centre-top prompt that tells the user, in plain words and an arrow,
/// where the next coverage gap is. Stays small ("✓ Covered") when the
/// scene is well covered so it doesn't dominate the frame.
class DirectionPrompt extends StatelessWidget {
  const DirectionPrompt({
    super.key,
    required this.next,
    required this.currentAzimuthDeg,
    required this.currentElevationDeg,
  });

  /// Suggested direction from [CoverageMap.suggestNextDirection]. Null
  /// means "everything is covered" — we show a quiet checkmark.
  final NextDirection? next;
  final double currentAzimuthDeg;
  final double currentElevationDeg;

  @override
  Widget build(BuildContext context) {
    if (next == null) {
      return const _PromptCard(
        icon: Icons.check_circle_outline,
        text: 'Coverage looks good',
        accent: Colors.lightGreenAccent,
        compact: true,
      );
    }

    // Relative arrow direction = where the user must rotate FROM their
    // current heading TO the suggested gap. We take the shortest azimuth
    // arc and combine it with the elevation delta so the arrow can point
    // up-right, down-left, etc.
    final azDelta = _shortestArc(currentAzimuthDeg, next!.azimuthDeg);
    final elDelta = next!.elevationDeg - currentElevationDeg;
    final arrowAngleRad = math.atan2(azDelta, -elDelta);

    final label = _labelFor(next!, azDelta, elDelta);

    return _PromptCard(
      icon: Icons.navigation,
      iconRotation: arrowAngleRad,
      text: label,
      accent: Colors.amberAccent,
    );
  }

  String _labelFor(NextDirection nd, double azDelta, double elDelta) {
    final horiz =
        azDelta.abs() < 8 ? 'ahead' : (azDelta > 0 ? 'right' : 'left');
    switch (nd.kind) {
      case NextDirectionKind.tiltUp:
        return horiz == 'ahead'
            ? 'Tilt up at the ceiling'
            : 'Tilt up to the $horiz';
      case NextDirectionKind.tiltDown:
        return horiz == 'ahead'
            ? 'Tilt down toward the floor'
            : 'Tilt down to the $horiz';
      case NextDirectionKind.pan:
        if (azDelta.abs() > 120) return 'Spin around — gap is behind you';
        return 'Pan ${azDelta > 0 ? "right" : "left"}';
      case NextDirectionKind.combined:
        final v = elDelta > 0 ? 'up' : 'down';
        return 'Look $horiz and $v';
      case NextDirectionKind.none:
        return 'Coverage looks good';
    }
  }

  static double _shortestArc(double from, double to) {
    final d = ((to - from) % 360 + 540) % 360 - 180;
    return d;
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.icon,
    required this.text,
    required this.accent,
    this.iconRotation = 0.0,
    this.compact = false,
  });

  final IconData icon;
  final String text;
  final Color accent;
  final double iconRotation;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: compact ? 60 : 24, vertical: 8),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 18,
        vertical: compact ? 8 : 12,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.45), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: iconRotation,
            child: Icon(icon, color: accent, size: compact ? 18 : 26),
          ),
          SizedBox(width: compact ? 6 : 12),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 13 : 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
