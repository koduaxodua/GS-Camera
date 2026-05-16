// Smoke test — verifies the app boots without throwing.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gs_camera/main.dart';

void main() {
  testWidgets('App boots into permission or capture flow', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GSCameraApp()));
    await tester.pump();
    final captureReady = find.text('Smart').evaluate().isNotEmpty &&
        find.text('Finish').evaluate().isNotEmpty;
    final permissionGate = find.text('Allow camera').evaluate().isNotEmpty ||
        find.text('Checking camera access').evaluate().isNotEmpty;
    expect(captureReady || permissionGate, isTrue);
  });
}
