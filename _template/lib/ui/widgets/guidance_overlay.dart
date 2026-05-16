import 'package:flutter/material.dart';

import '../../core/capture_coordinator.dart';

/// Soft, non-blocking hint banner that appears at the top of the capture
/// screen when the coordinator surfaces a [GuidanceHint].
///
/// Stays out of the way otherwise — most sessions never see one.
class GuidanceOverlay extends StatelessWidget {
  const GuidanceOverlay({super.key, required this.hint});

  final GuidanceHint hint;

  @override
  Widget build(BuildContext context) {
    final spec = _hintSpec(hint);
    if (spec == null) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Container(
        key: ValueKey(hint),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: spec.color.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(spec.icon, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                spec.message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _HintSpec? _hintSpec(GuidanceHint h) {
    switch (h) {
      case GuidanceHint.none:
        return null;
      case GuidanceHint.wipeLens:
        return _HintSpec(Icons.cleaning_services, Colors.blueGrey,
            'Wipe your camera lens with a soft cloth.');
      case GuidanceHint.addLight:
        return _HintSpec(Icons.lightbulb_outline, Colors.amber.shade700,
            'Add light — open curtains or turn on a lamp.');
      case GuidanceHint.reduceDirectLight:
        return _HintSpec(Icons.wb_sunny_outlined, Colors.deepOrange,
            'Avoid pointing the camera at the sun or a bright lamp.');
      case GuidanceHint.moveSlower:
        return _HintSpec(Icons.slow_motion_video, Colors.deepPurple,
            'Move slower — frames are too blurry.');
      case GuidanceHint.holdSteadier:
        return _HintSpec(Icons.pan_tool_alt_outlined, Colors.deepPurple,
            'Hold the phone steadier.');
      case GuidanceHint.continueMoving:
        return _HintSpec(Icons.rotate_right, Colors.indigo,
            'Continue rotating to capture more angles.');
      case GuidanceHint.alreadyCovered:
        return _HintSpec(Icons.check_circle_outline, Colors.teal,
            'This angle is already covered — try a new direction.');
      case GuidanceHint.lookAtGap:
        return _HintSpec(Icons.explore_outlined, Colors.indigo,
            'A gap was spotted — look around to find it.');
    }
  }
}

class _HintSpec {
  _HintSpec(this.icon, this.color, this.message);
  final IconData icon;
  final Color color;
  final String message;
}
