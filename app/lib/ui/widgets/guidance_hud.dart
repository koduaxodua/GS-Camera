import 'package:flutter/material.dart';

import '../../core/app_strings.dart';
import '../../core/capture_coordinator.dart';

class GuidanceHUD extends StatelessWidget {
  const GuidanceHUD({super.key, required this.guidance});

  final CaptureGuidance guidance;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: Container(
        key: ValueKey('${guidance.text}_${guidance.iconName}'),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: (guidance.arrowDegrees ?? 0) * 0.017453292519943295,
              child: Icon(
                _iconFor(guidance.iconName),
                color: Colors.white,
                size: 28,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _localizedText(guidance.text),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _localizedText(String text) {
    // Strip the checkmark for localization lookup
    final cleanText = text.replaceAll('✓ ', '');
    final localized = AppStrings.getGuidance(cleanText, 'en');
    // Re-add checkmark if it was present
    if (text.startsWith('✓ ')) {
      return '✓ $localized';
    }
    return localized;
  }

  IconData _iconFor(String name) {
    return switch (name) {
      'check_circle' => Icons.check_circle,
      'turn_right' => Icons.turn_right,
      'turn_left' => Icons.turn_left,
      'arrow_downward' => Icons.arrow_downward,
      'arrow_upward' => Icons.arrow_upward,
      'speed' => Icons.slow_motion_video,
      'pan_tool' => Icons.pan_tool_alt,
      'dark_mode' => Icons.dark_mode,
      'wb_sunny' => Icons.wb_sunny,
      'center_focus_strong' => Icons.center_focus_strong,
      'add' => Icons.add_circle_outline,
      _ => Icons.explore,
    };
  }
}
