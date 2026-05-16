import 'package:flutter/material.dart';

/// Capture modes tuned for different Gaussian Splatting scenarios.
///
/// Each mode controls trigger thresholds in the [CaptureCoordinator],
/// the dedup gate's similarity threshold, and the expected coverage
/// pattern in the [CoverageMap].
///
/// The numbers below were tuned empirically against the v0.2 field test
/// in a Tbilisi flat (134 kept / 72 deduped → 35 % reduction). Goal for
/// v0.3: 70 %+ reduction without losing coverage. Lowering Room's
/// similarity threshold to 0.86 is the biggest lever there — Room scans
/// produce many near-identical wall shots that 0.92 was letting through.
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
    similarityThreshold: 0.86,
    maxPhotosPerBin: 2,
  ),

  /// Orbit around a single piece of furniture or fixture.
  /// Triggers purely on rotation around the orbit center.
  object(
    label: 'Object',
    description: 'Orbit a piece of furniture',
    icon: Icons.chair_outlined,
    rotationStepDegrees: 5.0,
    translationStepMeters: double.infinity,
    // PlayCanvas / Reflct guidance: 100–200 photos for medium objects.
    targetShotCount: 120,
    minCoverageFraction: 0.85,
    // Object orbits intentionally make small angle changes — keep more
    // unique-looking neighbours by being stricter about what counts as a
    // duplicate.
    similarityThreshold: 0.93,
    maxPhotosPerBin: 3,
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
    similarityThreshold: 0.88,
    maxPhotosPerBin: 2,
  );

  const CaptureMode({
    required this.label,
    required this.description,
    required this.icon,
    required this.rotationStepDegrees,
    required this.translationStepMeters,
    required this.targetShotCount,
    required this.minCoverageFraction,
    required this.similarityThreshold,
    required this.maxPhotosPerBin,
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

  /// Cosine similarity at-or-above which two captures are treated as
  /// duplicates of the same view by the dedup gate.
  final double similarityThreshold;

  /// Hard cap on photos kept in any one (azimuth, elevation) bin.
  final int maxPhotosPerBin;
}
