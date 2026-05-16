import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import '../models/photo_meta.dart';

/// Snapshot of how far along an in-flight export is. Streamed by
/// [Exporter.writeSessionStream] so the review screen can render an
/// honest live progress bar rather than a generic spinner.
class ExportProgress {
  ExportProgress({
    required this.filesDone,
    required this.filesTotal,
    required this.currentName,
    required this.fraction,
    required this.finished,
    this.finalArchive,
    this.outputDir,
  });

  final int filesDone;
  final int filesTotal;
  final String currentName;

  /// 0.0 .. 1.0
  final double fraction;
  final bool finished;

  /// Set on the final event when the export was a ZIP.
  final File? finalArchive;

  /// Set on the final event when the export was a folder.
  final Directory? outputDir;
}

/// Writes the captured session to disk in a postshot-friendly layout.
///
/// Two output modes:
///   - **folder**: `Session_YYYY-MM-DD_HHMM/` with sequential JPEGs +
///     `session.json` + `README.txt`. Drop straight into postshot.
///   - **zip**: same logical contents bundled into a single `.zip` so
///     it's trivial to AirDrop / WhatsApp / email to the desktop. JPEGs
///     are stored without recompression to preserve the locked-exposure
///     pixel values; the JSON / README go in compressed.
class Exporter {
  /// Builds the export folder path. We use the app's external files dir
  /// — no storage permission needed and the Files app sees it under
  /// `Internal storage > Android > data > com.gscamera.gs_camera > files`.
  static Future<Directory> sessionDir(DateTime startedAt) async {
    final ts = _stampFor(startedAt);
    final base = await _exportRoot();
    final dir = Directory('${base.path}/Session_$ts');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _exportRoot() async {
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final root = Directory('${ext.path}/GSCamera');
        await root.create(recursive: true);
        return root;
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/GSCamera');
    await root.create(recursive: true);
    return root;
  }

  /// Stream-based export. Emits one [ExportProgress] event per file +
  /// one final event with `finished: true` and either [outputDir] or
  /// [finalArchive] set.
  static Stream<ExportProgress> writeSessionStream({
    required Directory destination,
    required List<PhotoMeta> shots,
    required Map<String, dynamic> sessionInfo,
    bool asZip = false,
  }) async* {
    final kept = shots.where((p) => p.keptInExport).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final total = kept.length + 2; // photos + session.json + README.txt

    if (asZip) {
      yield* _writeZip(
        destination: destination,
        shots: kept,
        sessionInfo: sessionInfo,
        total: total,
      );
    } else {
      yield* _writeFolder(
        destination: destination,
        shots: kept,
        sessionInfo: sessionInfo,
        total: total,
      );
    }
  }

  /// Backward-compatible synchronous helper. Drains the stream, returns
  /// when the final event arrives. Kept so older call sites don't break.
  static Future<void> writeSession({
    required Directory destination,
    required List<PhotoMeta> shots,
    required Map<String, dynamic> sessionInfo,
  }) async {
    await writeSessionStream(
      destination: destination,
      shots: shots,
      sessionInfo: sessionInfo,
      asZip: false,
    ).drain();
  }

  static Stream<ExportProgress> _writeFolder({
    required Directory destination,
    required List<PhotoMeta> shots,
    required Map<String, dynamic> sessionInfo,
    required int total,
  }) async* {
    var done = 0;
    // Use sequential 0001.jpg, 0002.jpg, ... numbering on the destination
    // side so postshot sees a contiguous image sequence even when dedup
    // skipped capture indexes mid-session.
    var seq = 0;
    for (final s in shots) {
      seq++;
      final padded = seq.toString().padLeft(4, '0');
      final cameraDir = Directory('${destination.path}/images/${s.camera}');
      await cameraDir.create(recursive: true);
      final destPath = '${cameraDir.path}/$padded.jpg';
      try {
        final src = File(s.absolutePath);
        if (await src.exists()) {
          try {
            await src.rename(destPath);
          } catch (_) {
            // Cross-volume rename can fail; fall back to copy+delete.
            await src.copy(destPath);
            await src.delete();
          }
          // Track the new on-disk location so a re-export (e.g. user
          // toggling between folder and ZIP) can find the file again.
          s.absolutePath = destPath;
          s.filename = '$padded.jpg';
        } else if (await File(destPath).exists()) {
          // Already at destination from a previous export attempt — make
          // sure the meta tracks it.
          s.absolutePath = destPath;
          s.filename = '$padded.jpg';
        }
      } catch (e) {
        // Per-file failures are non-fatal for the export — log and move on.
        // ignore: avoid_print
        print('export: skipped ${s.filename}: $e');
      }
      done++;
      yield ExportProgress(
        filesDone: done,
        filesTotal: total,
        currentName: '$padded.jpg',
        fraction: done / total,
        finished: false,
      );
    }

    try {
      await _writeSessionJson(
        destination: destination,
        shots: shots,
        sessionInfo: sessionInfo,
      );
    } catch (e) {
      // ignore: avoid_print
      print('export: session.json failed: $e');
    }
    done++;
    yield ExportProgress(
      filesDone: done,
      filesTotal: total,
      currentName: 'session.json',
      fraction: done / total,
      finished: false,
    );

    try {
      await _writeReadme(destination);
    } catch (e) {
      // ignore: avoid_print
      print('export: README failed: $e');
    }
    done++;
    yield ExportProgress(
      filesDone: done,
      filesTotal: total,
      currentName: 'README.txt',
      fraction: 1.0,
      finished: true,
      outputDir: destination,
    );
  }

  static Stream<ExportProgress> _writeZip({
    required Directory destination,
    required List<PhotoMeta> shots,
    required Map<String, dynamic> sessionInfo,
    required int total,
  }) async* {
    final zipPath = '${destination.path}.zip';
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    var done = 0;
    var seq = 0;
    try {
      for (final s in shots) {
        seq++;
        final padded = seq.toString().padLeft(4, '0');
        try {
          final src = File(s.absolutePath);
          if (await src.exists()) {
            // ZIP DEFLATE is lossless on the file bytes, so a JPEG
            // extracted from this archive is byte-identical to the
            // original — postshot sees the same pixel values.
            // We DO NOT delete the source here: the user might toggle
            // back to folder mode or re-export, and we don't want to
            // lose the originals on a single ZIP run.
            await encoder.addFile(src, 'images/${s.camera}/$padded.jpg');
          }
        } catch (e) {
          // ignore: avoid_print
          print('export(zip): skipped ${s.filename}: $e');
        }
        done++;
        yield ExportProgress(
          filesDone: done,
          filesTotal: total,
          currentName: '$padded.jpg',
          fraction: done / total,
          finished: false,
        );
      }

      try {
        final jsonStr = const JsonEncoder.withIndent('  ').convert({
          ...sessionInfo,
          'shot_count': shots.length,
          'shots': shots.map((s) => s.toJson()).toList(),
        });
        encoder.addArchiveFile(
          ArchiveFile.string('session.json', jsonStr),
        );
      } catch (e) {
        // ignore: avoid_print
        print('export(zip): session.json failed: $e');
      }
      done++;
      yield ExportProgress(
        filesDone: done,
        filesTotal: total,
        currentName: 'session.json',
        fraction: done / total,
        finished: false,
      );

      try {
        encoder.addArchiveFile(
          ArchiveFile.string('README.txt', _readmeBody),
        );
      } catch (e) {
        // ignore: avoid_print
        print('export(zip): README failed: $e');
      }
      done++;
    } finally {
      await encoder.close();
    }

    try {
      if (await destination.exists() && (await destination.list().isEmpty)) {
        await destination.delete();
      }
    } catch (_) {/* best effort */}

    yield ExportProgress(
      filesDone: total,
      filesTotal: total,
      currentName: 'Session.zip',
      fraction: 1.0,
      finished: true,
      finalArchive: File(zipPath),
    );
  }

  static Future<void> _writeSessionJson({
    required Directory destination,
    required List<PhotoMeta> shots,
    required Map<String, dynamic> sessionInfo,
  }) async {
    final meta = {
      ...sessionInfo,
      'shot_count': shots.length,
      'shots': shots.map((s) => s.toJson()).toList(),
    };
    await File('${destination.path}/session.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
  }

  static Future<void> _writeReadme(Directory destination) async {
    await File('${destination.path}/README.txt').writeAsString(_readmeBody);
  }

  static const _readmeBody = '''
GS Camera session — for postshot

Drop this entire folder into postshot as an "image sequence" project.
- Frames are JPEG, sequential, EXIF preserved.
- Camera exposure/focus/white balance were locked across all frames.
- session.json contains sensor metadata (azimuth/elevation/roll, sharpness
  score, ISO, shutter). postshot ignores it; it is there in case a custom
  GS pipeline wants known camera poses.

If postshot still chokes:
1. Check that all frames are similar exposure (open a few in viewer).
2. If a few frames look soft, delete them and re-import.
3. Aim for at least 60-100 frames for an interior; 200+ for big rooms.
''';

  static String _stampFor(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}';
  }
}
