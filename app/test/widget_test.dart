// Smoke test — verifies the app boots without throwing.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gs_camera/main.dart';

void main() {
  testWidgets('App boots and keeps Finish visible', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GSCameraApp()));
    await tester.pump();
    expect(find.text('Smart'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);
  });
}
