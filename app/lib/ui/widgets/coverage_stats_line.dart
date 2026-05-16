import 'package:flutter/material.dart';

/// Single-line stats strip pinned just above the bottom Finish button.
/// Shows photo count + coverage % + dedup count so the user can see at a
/// glance that the ML layer is doing its job.
class CoverageStatsLine extends StatelessWidget {
  const CoverageStatsLine({
    super.key,
    required this.photoCount,
    required this.coverageFraction,
    required this.dedupedCount,
    required this.modeLabel,
  });

  final int photoCount;
  final double coverageFraction;
  final int dedupedCount;
  final String modeLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _Cell(label: 'Photos', value: photoCount.toString()),
        _Cell(
          label: 'Covered',
          value: '${(coverageFraction * 100).round()}%',
        ),
        _Cell(
          label: 'Deduped',
          value: dedupedCount.toString(),
          highlight: dedupedCount > 0,
        ),
        _Cell(label: 'Mode', value: modeLabel),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final valueColor = highlight ? Colors.lightGreenAccent : Colors.white;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55), fontSize: 11),
        ),
      ],
    );
  }
}
