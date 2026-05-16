import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class ExportService {
  Future<Directory> processSession({
    required String sessionId,
    required String destDirPath,
    required List<Map<String, dynamic>> photos,
    required Map<dynamic, dynamic> coverageMap,
  }) async {
    final dest = Directory(destDirPath);
    if (!await dest.exists()) await dest.create(recursive: true);
    return dest;
  }
}

final exportServiceProvider = Provider<ExportService>((ref) => ExportService());
