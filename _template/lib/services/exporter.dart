import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/photo_meta.dart';

/// Writes the captured session into a folder structure postshot can ingest:
///
/// ```
/// DCIM/GSCamera/Session_2026-04-25_1530/
///   0001.jpg
///   0002.jpg
///   ...
///   session.json     # sensor metadata, optional input to GS pipelines
///   README.txt       # plain-English drop-into-postshot instructions
/// ```
class Exporter {
  /// Builds the export folder path. On Android we want it in DCIM so the
  /// Files app and USB transfer pick it up automatically.
  static Future<Directory> sessionDir(DateTime startedAt) async {
    final ts = _stampFor(startedAt);
    final base = await _exportRoot();
    final dir = Directory('${base.path}/Session_$ts');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _exportRoot() async {
    // Try DCIM first (visible to MTP/USB transfer); fall back to app docs.
    if (Platform.isAndroid) {
      final dcim = Directory('/storage/emulated/0/DCIM/GSCamera');
      try {
        await dcim.create(recursive: true);
        return dcim;
      } catch (_) {/* permissions issue, fall through */}
    }
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/GSCamera');
    await root.create(recursive: true);
    return root;
  }

  /// Move/copy the captured JPEGs into the session folder, renaming them
  /// to the sequential `0001.jpg`, `0002.jpg`, ... pattern.
  static Future<void> writeSession({
    required Directory destination,
    required List<PhotoMeta> shots,
    required Map<String, dynamic> sessionInfo,
  }) async {
    for (final s in shots) {
      final src = File(s.filename);
      if (!await src.exists()) continue;
      final padded = s.index.toString().padLeft(4, '0');
      await src.rename('${destination.path}/$padded.jpg');
    }

    final meta = {
      ...sessionInfo,
      'shot_count': shots.length,
      'shots': shots.map((s) => s.toJson()).toList(),
    };
    await File('${destination.path}/session.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(meta));

    await File('${destination.path}/README.txt').writeAsString('''
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
''');
  }

  static String _stampFor(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}';
  }
}
