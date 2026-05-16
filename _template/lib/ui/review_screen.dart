import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/capture_mode.dart';
import '../models/photo_meta.dart';
import '../services/exporter.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.mode,
    required this.shots,
    required this.coverage,
  });

  final CaptureMode mode;
  final List<PhotoMeta> shots;
  final double coverage;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Directory? _exportedTo;
  bool _exporting = true;

  @override
  void initState() {
    super.initState();
    _runExport();
  }

  Future<void> _runExport() async {
    final dir = await Exporter.sessionDir(DateTime.now());
    await Exporter.writeSession(
      destination: dir,
      shots: widget.shots,
      sessionInfo: {
        'mode': widget.mode.name,
        'coverage_fraction': widget.coverage,
        'app_version': '0.1.0',
      },
    );
    if (!mounted) return;
    setState(() {
      _exportedTo = dir;
      _exporting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final avgSharp = widget.shots.isEmpty
        ? 0.0
        : widget.shots.map((s) => s.sharpness).reduce((a, b) => a + b) /
            widget.shots.length;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Session complete',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(widget.mode.label,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6), fontSize: 14)),
              const SizedBox(height: 24),
              _StatBlock('Photos', widget.shots.length.toString()),
              _StatBlock('Coverage', '${(widget.coverage * 100).round()}%'),
              _StatBlock('Avg sharpness', avgSharp.toStringAsFixed(1)),
              const SizedBox(height: 24),
              if (_exporting)
                const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                    SizedBox(width: 12),
                    Text('Saving to DCIM…',
                        style: TextStyle(color: Colors.white70)),
                  ],
                )
              else if (_exportedTo != null)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B20),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Saved to',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 4),
                      Text(_exportedTo!.path,
                          style: const TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
              const Spacer(),
              if (!_exporting && _exportedTo != null)
                ElevatedButton.icon(
                  onPressed: () => Share.shareXFiles(
                    [XFile(_exportedTo!.path)],
                    subject: 'GS Camera session',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share folder',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
                child: const Text('Done',
                    style: TextStyle(color: Colors.white70, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6), fontSize: 14)),
          ),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
