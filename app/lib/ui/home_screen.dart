import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/capture_mode.dart';
import 'capture_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('GS Camera',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('Photos optimised for Gaussian Splatting',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.62),
                      fontSize: 15)),
              const SizedBox(height: 32),
              for (final mode in CaptureMode.values) ...[
                _ModeCard(
                  mode: mode,
                  onTap: () => _start(context, mode),
                ),
                const SizedBox(height: 14),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _start(BuildContext context, CaptureMode mode) async {
    // Only the camera permission is actually required:
    // - sensors_plus motion sensors don't need a runtime permission
    // - file output goes to the app's external files dir, no storage perm needed
    final status = await Permission.camera.request();
    if (!context.mounted) return;
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status.isPermanentlyDenied
            ? 'Camera access is denied — open Settings to grant it.'
            : 'Camera access is required to capture photos.'),
        action: status.isPermanentlyDenied
            ? const SnackBarAction(
                label: 'Settings', onPressed: openAppSettings)
            : null,
      ));
      return;
    }
    await Permission.notification.request();
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const CaptureScreen(),
    ));
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode, required this.onTap});

  final CaptureMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B1B20),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF26262E),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(mode.icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(mode.label,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(mode.description,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 14)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}
