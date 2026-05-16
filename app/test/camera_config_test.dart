import 'package:flutter_test/flutter_test.dart';
import 'package:gs_camera/core/coverage_tracker.dart';
import 'package:gs_camera/services/camera_service.dart';

void main() {
  test('two-lens inventory does not report fake tele support', () {
    final config = CameraConfig.fromMap({
      'iso': 100,
      'shutter_speed_ns': 8000000,
      'exposure_value': 0.8,
      'focus_distance': 0,
      'preview_width': 320,
      'preview_height': 240,
      'capture_width': 4608,
      'capture_height': 3456,
      'texture_id': 1,
      'display_preview_width': 1280,
      'display_preview_height': 720,
      'sensor_orientation': 90,
      'camera_index': 1,
      'camera_name': 'main',
      'camera_id': '0',
      'focal_length_mm': 4.3,
      'available_lenses': ['uw', 'main'],
      'camera_inventory': [
        {
          'camera_id': '2',
          'camera_name': 'uw',
          'focal_length_mm': 1.8,
          'real_tele': false,
        },
        {
          'camera_id': '0',
          'camera_name': 'main',
          'focal_length_mm': 4.3,
          'real_tele': false,
        },
      ],
    });

    expect(config.lensType, CameraLensType.main);
    expect(config.hasTeleCamera, isFalse);
    expect(config.supports(CameraLensType.tele), isFalse);
    expect(config.availableLenses, [CameraLensType.uw, CameraLensType.main]);
  });

  test('tele support requires native real tele inventory flag', () {
    final config = CameraConfig.fromMap({
      'camera_name': 'main',
      'camera_id': '0',
      'focal_length_mm': 4.3,
      'available_lenses': ['uw', 'main', 'tele'],
      'camera_inventory': [
        {
          'camera_id': '2',
          'camera_name': 'uw',
          'focal_length_mm': 1.8,
          'real_tele': false,
        },
        {
          'camera_id': '0',
          'camera_name': 'main',
          'focal_length_mm': 4.3,
          'real_tele': false,
        },
        {
          'camera_id': '3',
          'camera_name': 'tele',
          'focal_length_mm': 9.0,
          'real_tele': true,
        },
      ],
    });

    expect(config.hasTeleCamera, isTrue);
    expect(config.supports(CameraLensType.tele), isTrue);
  });
}
