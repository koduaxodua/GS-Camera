import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/capture_mode.dart';
import '../models/photo_meta.dart';
import '../services/camera_service.dart';
import '../services/exporter.dart';
import '../services/native_export_service.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.mode,
    required this.shots,
    required this.coverage,
    required this.dedupedCount,
    required this.coverageMap,
    required this.perCameraCoverage,
  });

  final CaptureMode mode;
  final List<PhotoMeta> shots;
  final double coverage;
  final int dedupedCount;
  final Map<String, dynamic> coverageMap;
  final Map<String, double> perCameraCoverage;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Directory? _exportedDir;
  File? _exportedZip;
  bool _exporting = false;
  bool _exportAsZip = false;
  ExportProgress? _progress;
  int _manualDeletes = 0;
  bool _backgroundExport = false;

  @override
  void initState() {
    super.initState();
    _runExport();
  }

  Future<void> _runExport() async {
    setState(() {
      _exporting = true;
      _backgroundExport = false;
      _progress = null;
      _exportedDir = null;
      _exportedZip = null;
    });

    if (Platform.isAndroid) {
      try {
        final sessionInfo = await _sessionInfo();
        final started = await NativeExportService.start(
          shots: widget.shots,
          sessionInfo: sessionInfo,
          asZip: _exportAsZip,
        );
        if (!mounted) return;
        setState(() {
          _exporting = false;
          _backgroundExport = true;
          if (started.asZip) {
            _exportedZip = File(started.outputPath);
          } else {
            _exportedDir = Directory(started.outputPath);
          }
        });
        return;
      } catch (e) {
        // If native foreground export cannot start, keep the old in-app
        // exporter as a fallback.
        // ignore: avoid_print
        print('native export failed, falling back to Dart exporter: $e');
      }
    }

    final dir = await Exporter.sessionDir(DateTime.now());
    final sessionInfo = await _sessionInfo();
    final stream = Exporter.writeSessionStream(
      destination: dir,
      shots: widget.shots,
      sessionInfo: sessionInfo,
      asZip: _exportAsZip,
    );

    await for (final p in stream) {
      if (!mounted) return;
      setState(() {
        _progress = p;
        if (p.finished) {
          _exporting = false;
          _exportedDir = p.outputDir;
          _exportedZip = p.finalArchive;
        }
      });
    }
  }

  Future<Map<String, dynamic>> _sessionInfo() async {
    var cameraModels = const <String, dynamic>{};
    try {
      final intrinsics = await CameraService.instance.getAllIntrinsics();
      final usedCameras = widget.shots.map((shot) => shot.camera).toSet();
      final presentIntrinsics = usedCameras.isEmpty
          ? intrinsics
          : Map.fromEntries(
              intrinsics.entries
                  .where((entry) => usedCameras.contains(entry.key)),
            );
      cameraModels = presentIntrinsics.map(
        (key, value) => MapEntry(key, value.toJson()),
      );
    } catch (_) {
      cameraModels = const <String, dynamic>{};
    }
    return {
      'mode': widget.mode.name,
      'coverage_fraction': widget.coverage,
      'deduped_count': widget.dedupedCount,
      'manual_deletes': _manualDeletes,
      'app_version': '0.3.0',
      'camera_models': cameraModels,
      'pro_export': false,
      'coverage_map': widget.coverageMap,
      'per_camera_coverage': widget.perCameraCoverage,
      'colmap_sparse_stub': 'not_generated',
      'sdf_export_stub': 'disabled',
    };
  }

  Future<void> _confirmDelete(PhotoMeta meta) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B20),
        title: const Text('Delete this photo?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'It will be removed from the export and the file deleted.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    meta.keptInExport = false;
    _manualDeletes++;
    try {
      final f = File(meta.absolutePath);
      if (await f.exists()) await f.delete();
    } catch (_) {/* best effort */}

    if (!mounted) return;
    setState(() {/* drop from grid */});
    // Re-export so the on-disk session and session.json reflect the
    // deletion immediately.
    await _runExport();
  }

  @override
  Widget build(BuildContext context) {
    final keptShots = widget.shots.where((s) => s.keptInExport).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final finiteSharps =
        keptShots.where((s) => s.sharpness.isFinite).map((s) => s.sharpness);
    final avgSharp = finiteSharps.isEmpty
        ? 0.0
        : finiteSharps.fold<double>(0, (a, b) => a + b) / finiteSharps.length;
    final dedupRatio = (keptShots.length + widget.dedupedCount) == 0
        ? 0.0
        : widget.dedupedCount / (keptShots.length + widget.dedupedCount);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0C),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Session complete',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(widget.mode.label,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 14)),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _StatBlock('Photos kept', keptShots.length.toString()),
                    _StatBlock(
                      'Coverage',
                      '${(widget.coverage * 100).round()}%',
                    ),
                    _StatBlock('Avg sharpness', avgSharp.toStringAsFixed(1)),
                    if (widget.dedupedCount > 0)
                      _StatBlock(
                        'Deduped',
                        '${widget.dedupedCount} '
                            '(${(dedupRatio * 100).round()}%)',
                      ),
                    const SizedBox(height: 18),
                    if (keptShots.isNotEmpty)
                      _ThumbnailStrip(
                        shots: keptShots,
                        onDelete: (_exporting || _backgroundExport)
                            ? null
                            : _confirmDelete,
                      ),
                    const SizedBox(height: 18),
                    _exportControlBlock(),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Column(
                children: [
                  if (!_exporting) _shareButton(),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).popUntil((r) => r.isFirst),
                    child: const Text('Done',
                        style: TextStyle(color: Colors.white70, fontSize: 16)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _exportControlBlock() {
    if (_exporting) {
      final p = _progress;
      final fraction = p?.fraction ?? 0;
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B20),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p == null
                  ? 'Preparing export…'
                  : 'Exporting ${p.filesDone} / ${p.filesTotal}'
                      ' — ${p.currentName} '
                      '(${(p.fraction * 100).round()}%)',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: p == null ? null : fraction,
                backgroundColor: Colors.white10,
                valueColor:
                    const AlwaysStoppedAnimation(Colors.lightGreenAccent),
                minHeight: 6,
              ),
            ),
          ],
        ),
      );
    }

    final outputPath = _exportedZip?.path ?? _exportedDir?.path ?? '—';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              if (_backgroundExport) ...[
                const Text(
                  'Export continues in notifications.',
                  style:
                      TextStyle(color: Colors.lightGreenAccent, fontSize: 12),
                ),
                const SizedBox(height: 6),
              ],
              Text(outputPath,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Bundle as a single .zip',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ),
            Switch(
              value: _exportAsZip,
              onChanged: _backgroundExport
                  ? null
                  : (v) {
                      setState(() => _exportAsZip = v);
                      _runExport();
                    },
              activeThumbColor: Colors.lightGreenAccent,
            ),
          ],
        ),
      ],
    );
  }

  Widget _shareButton() {
    final target = _exportedZip?.path ?? _exportedDir?.path;
    if (target == null || _backgroundExport) return const SizedBox.shrink();
    return ElevatedButton.icon(
      onPressed: () => Share.shareXFiles(
        [XFile(target)],
        subject: 'GS Camera session',
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: const Icon(Icons.ios_share),
      label: Text(_exportedZip != null ? 'Share .zip' : 'Share folder',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    );
  }
}

/// Horizontally-scrollable strip of all kept captures. Tap a thumbnail
/// to confirm-delete it from the export — the stream re-runs so the
/// resulting folder/zip stays consistent with what the user reviewed.
class _ThumbnailStrip extends StatelessWidget {
  const _ThumbnailStrip({required this.shots, required this.onDelete});

  final List<PhotoMeta> shots;

  /// Null while an export is in flight (delete is disabled then).
  final Future<void> Function(PhotoMeta)? onDelete;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: shots.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final meta = shots[i];
          return _ThumbnailTile(
            meta: meta,
            onTap: onDelete == null ? null : () => onDelete!(meta),
          );
        },
      ),
    );
  }
}

class _ThumbnailTile extends StatelessWidget {
  const _ThumbnailTile({required this.meta, required this.onTap});

  final PhotoMeta meta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: const Color(0xFF1B1B20),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(meta.absolutePath),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white24),
              ),
            ),
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  meta.index.toString(),
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
            if (onTap != null)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.delete_outline,
                      color: Colors.redAccent, size: 14),
                ),
              ),
          ],
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
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
