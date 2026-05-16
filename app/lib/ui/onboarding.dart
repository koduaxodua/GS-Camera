import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers.dart';

class OnboardingOverlay extends ConsumerStatefulWidget {
  const OnboardingOverlay({super.key});

  @override
  ConsumerState<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends ConsumerState<OnboardingOverlay> {
  bool _visible = false;
  int _step = 0;

  static const _steps = [
    (Icons.threesixty, 'Move slowly', 'Turn around and let the ring fill.'),
    (
      Icons.center_focus_strong,
      'Aim at gaps',
      'Follow the simple hint in the center.'
    ),
    (
      Icons.file_upload_outlined,
      'Leave export running',
      'Progress continues in notifications.'
    ),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('scanner_onboarding_seen') ?? false) && mounted) {
      setState(() => _visible = true);
    }
  }

  Future<void> _done() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('scanner_onboarding_seen', true);
    ref.read(onboardingSeenProvider.notifier).state = true;
    if (mounted) setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final step = _steps[_step];
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      child: SafeArea(
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF17171C),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(step.$1, color: Colors.white, size: 58),
                const SizedBox(height: 18),
                Text(
                  step.$2,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  step.$3,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: _step == _steps.length - 1
                      ? _done
                      : () => setState(() => _step++),
                  child: Text(_step == _steps.length - 1 ? 'Got it' : 'Next'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
