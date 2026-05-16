import 'dart:io';

import 'package:flutter/services.dart';

import '../models/photo_meta.dart';

class NativeExportStart {
  NativeExportStart({
    required this.outputPath,
    required this.asZip,
  });

  final String outputPath;
  final bool asZip;
}

class NativeExportService {
  static const _method = MethodChannel('gs_camera/control');

  static Future<NativeExportStart> start({
    required List<PhotoMeta> shots,
    required Map<String, dynamic> sessionInfo,
    required bool asZip,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Native background export is Android-only');
    }

    final result = await _method.invokeMapMethod<String, dynamic>(
      'startBackgroundExport',
      {
        'shots': shots
            .where((p) => p.keptInExport)
            .map((p) => {
                  'index': p.index,
                  'path': p.absolutePath,
                  'meta': p.toJson(),
                })
            .toList(),
        'session_info': sessionInfo,
        'as_zip': asZip,
      },
    );

    return NativeExportStart(
      outputPath: result!['output_path'] as String,
      asZip: result['as_zip'] as bool,
    );
  }
}
