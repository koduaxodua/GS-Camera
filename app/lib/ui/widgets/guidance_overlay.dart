import 'package:flutter/material.dart';

import '../../core/capture_coordinator.dart';
import 'guidance_hud.dart';

/// Compatibility wrapper kept for older imports. New capture UI uses
/// [GuidanceHUD] directly.
class GuidanceOverlay extends StatelessWidget {
  const GuidanceOverlay({
    super.key,
    this.guidance = const CaptureGuidance(
      text: 'Move slowly',
      iconName: 'explore',
    ),
  });

  final CaptureGuidance guidance;

  @override
  Widget build(BuildContext context) {
    return GuidanceHUD(guidance: guidance);
  }
}
