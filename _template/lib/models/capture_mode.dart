import 'package:flutter/material.dart';

/// Capture modes tuned for different Gaussian Splatting scenarios.
///
/// Each mode controls trigger thresholds in the [CaptureCoordinator] and
/// the expected coverage pattern in the [CoverageMap].
enum CaptureMode {
  /// Walk through a room and rotate; combo of translation + rotation triggers.
  /// Best for whole-apartment scans for the listings website.
  room(
    label: 'Room',
    description: 'Walk through and rotate',
    icon: Icons.home_outlined,
    rotationStepDegrees: 6.0,
    translationStepMeters: 0.30,
    targetShotCount: 200,
    minCoverageFraction: 0.70,
  ),

  /// Orbit around a single piece of furniture or fixture.
  /// Triggers purely on rotation around the orbit center.
  object(
    label: 'Object',
    description: 'Orbit a piece of furniture',
    icon: Icons.chair_outlined,
    rotationStepDegrees: 5.0,
    translationStepMeters: double.infinity,
    targetShotCount: 75,
    minCoverageFraction: 0.85,
  ),

  /// Stand in one spot and pan/tilt the phone to cover the full sphere.
  /// Useful for tight spaces where you can't move (closets, bathrooms).
  spherical(
    label: 'Spherical',
    description: 'Stand still, scan around',
    icon: Icons.threesixty,
    rotationStepDegrees: 7.0,
    translationStepMeters: double.infinity,
    targetShotCount: 50,
    minCoverageFraction: 0.75,
  );

  const CaptureMode({
    required this.label,
    required this.description,
    required this.icon,
    required this.rotationStepDegrees,
    required this.translationStepMeters,
    required this.targetShotCount,
    required this.minCoverageFraction,
  });

  final String label;
  final String description;
  final IconData icon;

  /// Minimum rotation since last shot before another shot is allowed.
  final double rotationStepDegrees;

  /// Minimum translation since last shot before another shot is allowed.
  /// `infinity` disables the translation trigger (rotation-only mode).
  final double translationStepMeters;

  final int targetShotCount;

  /// Fraction of expected coverage bins that must reach "green" before the
  /// session is considered complete.
  final double minCoverageFraction;
}
