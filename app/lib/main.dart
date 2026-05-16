import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/capture_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Pin portrait for now
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(
    const ProviderScope(
      child: GSCameraApp(),
    ),
  );
}

class GSCameraApp extends StatelessWidget {
  const GSCameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GS Camera',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0C),
      ),
      home: const CaptureScreen(),
    );
  }
}
