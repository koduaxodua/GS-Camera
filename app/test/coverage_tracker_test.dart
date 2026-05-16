import 'package:flutter_test/flutter_test.dart';
import 'package:gs_camera/core/coverage_tracker.dart';
import 'package:gs_camera/models/capture_mode.dart';

void main() {
  test('main-only captures turn a bin green and advance coverage', () {
    final tracker = CoverageTracker();
    addTearDown(tracker.dispose);

    for (var i = 0; i < 2; i++) {
      tracker.recordFrame(
        mode: CaptureMode.room,
        camera: CameraLensType.main,
        azimuthDeg: 4,
        elevationDeg: 0,
        sharpness: 0.9,
        textureScore: 0.5,
        qualityAccepted: true,
      );
    }

    final bin = tracker.binAt(
      mode: CaptureMode.room,
      azimuthDeg: 4,
      elevationDeg: 0,
    );
    expect(bin.color, CoverageBinColor.green);
    expect(tracker.value.coveragePercent, closeTo(100 / 36, 0.001));
  });

  test('uw-only capture is blue but does not advance coverage percent', () {
    final tracker = CoverageTracker();
    addTearDown(tracker.dispose);

    tracker.recordFrame(
      mode: CaptureMode.room,
      camera: CameraLensType.uw,
      azimuthDeg: 4,
      elevationDeg: 0,
      sharpness: 0.9,
      textureScore: 0.5,
      qualityAccepted: true,
    );

    final bin = tracker.binAt(
      mode: CaptureMode.room,
      azimuthDeg: 4,
      elevationDeg: 0,
    );
    expect(bin.color, CoverageBinColor.blue);
    expect(tracker.value.coveragePercent, 0);
    expect(tracker.needsQuality(4, 0, CaptureMode.room), isTrue);
  });
}
