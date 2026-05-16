import 'dart:typed_data';

/// Metadata recorded for every accepted capture, written to a session
/// sidecar JSON for postshot to consume alongside the JPEGs.
class PhotoMeta {
  PhotoMeta({
    required this.index,
    required this.filename,
    required this.absolutePath,
    required this.timestampMs,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.rollDeg,
    required this.position,
    required this.sharpness,
    required this.exposureLockValue,
    required this.iso,
    required this.shutterSpeedNs,
    this.camera = 'main',
    this.textureScore = 0,
    this.embedding,
    this.binAz = -1,
    this.binEl = -1,
    this.keptInExport = true,
  });

  /// Sequential index in the session (1-based).
  final int index;

  /// Just the basename, e.g. `0042.jpg`. Updated by [Exporter] after the
  /// file is moved into the final session folder so a re-export (e.g. the
  /// user toggling between folder and zip) doesn't go looking for the
  /// file at the original `tmp_NNN.jpg` path.
  String filename;

  /// Full path on the device. Mutable for the same reason as [filename]
  /// — exports update it to the new on-disk location.
  String absolutePath;

  final int timestampMs;

  /// 0-360, 0 = session start heading.
  final double azimuthDeg;

  /// -90 (down) to +90 (up).
  final double elevationDeg;

  final double rollDeg;

  /// Approximate translation since session start, integrated from accelerometer.
  /// Very rough — postshot's SfM does the real work, this is just for the
  /// coverage map.
  final ({double x, double y, double z}) position;

  /// Laplacian variance — higher is sharper. Sub-30 typically rejected.
  /// Mutable because the embedding pipeline may recompute it from the
  /// saved JPEG when the preview-frame snapshot at capture time was not
  /// yet a valid measurement.
  double sharpness;

  /// AE-lock target value at session start; the same for every photo.
  final double exposureLockValue;

  final int iso;
  final int shutterSpeedNs;
  final String camera;
  final double textureScore;

  double get uncertaintyScore => (1.0 - textureScore).clamp(0.0, 1.0);

  /// 1024-d feature vector from the on-device embedding model. Null when
  /// the model isn't available yet (first capture, init failure) — in
  /// that case the dedup gate falls back to spatial-only logic.
  Float32List? embedding;

  /// Cached coverage-map bin coordinates so the dedup gate doesn't have
  /// to recompute them. -1 means "not yet recorded into a bin".
  int binAz;
  int binEl;

  /// Set to false by the dedup gate when this photo gets superseded by
  /// a sharper one in the same bin. Exporter skips !keptInExport entries.
  bool keptInExport;

  Map<String, dynamic> toJson() => {
        'index': index,
        'filename': filename,
        'timestamp_ms': timestampMs,
        'azimuth_deg': azimuthDeg,
        'elevation_deg': elevationDeg,
        'roll_deg': rollDeg,
        'position': {'x': position.x, 'y': position.y, 'z': position.z},
        'sharpness': sharpness,
        'camera': camera,
        'texture_score': textureScore,
        'uncertainty_score': uncertaintyScore,
        'exposure_lock_value': exposureLockValue,
        'iso': iso,
        'shutter_speed_ns': shutterSpeedNs,
        'kept_in_export': keptInExport,
      };
}
