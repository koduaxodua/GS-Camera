/// Metadata recorded for every accepted capture, written to a session
/// sidecar JSON for postshot to consume alongside the JPEGs.
class PhotoMeta {
  PhotoMeta({
    required this.index,
    required this.filename,
    required this.timestampMs,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.rollDeg,
    required this.position,
    required this.sharpness,
    required this.exposureLockValue,
    required this.iso,
    required this.shutterSpeedNs,
  });

  /// Sequential index in the session (1-based).
  final int index;

  /// Just the basename, e.g. `0042.jpg`. Lives in the session folder.
  final String filename;

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
  final double sharpness;

  /// AE-lock target value at session start; the same for every photo.
  final double exposureLockValue;

  final int iso;
  final int shutterSpeedNs;

  Map<String, dynamic> toJson() => {
    'index': index,
    'filename': filename,
    'timestamp_ms': timestampMs,
    'azimuth_deg': azimuthDeg,
    'elevation_deg': elevationDeg,
    'roll_deg': rollDeg,
    'position': {'x': position.x, 'y': position.y, 'z': position.z},
    'sharpness': sharpness,
    'exposure_lock_value': exposureLockValue,
    'iso': iso,
    'shutter_speed_ns': shutterSpeedNs,
  };
}
