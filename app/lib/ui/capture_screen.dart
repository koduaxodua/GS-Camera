import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/capture_coordinator.dart';
import '../core/coverage_tracker.dart';
import '../models/capture_mode.dart';
import '../providers.dart';
import '../services/camera_service.dart';
import 'onboarding.dart';
import 'review_screen.dart';
import 'widgets/coverage_ring.dart';
import 'widgets/guidance_hud.dart';
import 'widgets/ml_status_badge.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen>
    with WidgetsBindingObserver {
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      ref.invalidate(captureCoordinatorProvider);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(captureCoordinatorProvider);
    final coverage = ref.watch(coverageTrackerProvider);
    final selectedMode = ref.watch(selectedModeProvider);

    if (coordinator.autoFinishExpired && !_finishing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _previewFor(coordinator.config)),
          if (coordinator.state == CaptureState.failed)
            _ErrorView(message: coordinator.errorMessage ?? 'Camera failed')
          else ...[
            _topModeBar(selectedMode, coordinator),
            Positioned(
              top: 76,
              left: 16,
              child: SafeArea(
                child: _GlassButton(
                  icon: Icons.flash_on,
                  label: 'Capture now',
                  onTap: coordinator.forceCapture,
                ),
              ),
            ),
            Positioned(
              top: 76,
              right: 16,
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _CoveragePill(percent: coverage.coveragePercent),
                    const SizedBox(height: 8),
                    const MlStatusBadge(),
                  ],
                ),
              ),
            ),
            Center(child: GuidanceHUD(guidance: coordinator.guidance)),
            Positioned(
              bottom: 58,
              left: 0,
              right: 0,
              child: Center(
                child: CoverageRing(
                  state: coverage,
                  currentYawDeg: coordinator.lastSensor?.azimuthDeg ?? 0,
                  showRoomBands: coordinator.mode == CaptureMode.room,
                ),
              ),
            ),
            if (coordinator.autoFinishActive)
              _AutoFinishSheet(
                seconds: coordinator.autoFinishSeconds,
                onAddMore: coordinator.addMore,
                onFinish: _finish,
              ),
            if (coordinator.state == CaptureState.preflight ||
                coordinator.state == CaptureState.locking)
              const _BusyOverlay(text: 'Getting camera ready'),
            if (coordinator.state == CaptureState.exporting)
              const _BusyOverlay(text: 'Reducing duplicate photos'),
            if (coordinator.canManualFinish)
              Positioned(
                right: 18,
                bottom: 22,
                child: SafeArea(
                  child: Semantics(
                    button: true,
                    label: 'Finish scan',
                    child: FloatingActionButton.extended(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      onPressed: _confirmFinish,
                      icon: const Icon(Icons.check),
                      label: const Text('Finish'),
                    ),
                  ),
                ),
              ),
            const OnboardingOverlay(),
          ],
        ],
      ),
    );
  }

  Widget _previewFor(CameraConfig? config) {
    if (config == null || config.textureId < 0) {
      return const ColoredBox(color: Colors.black);
    }
    final sensorW = config.displayPreviewWidth.toDouble();
    final sensorH = config.displayPreviewHeight.toDouble();
    final rotatedToPortrait = (config.sensorOrientation / 90).round().isOdd;
    final visualW = rotatedToPortrait ? sensorH : sensorW;
    final visualH = rotatedToPortrait ? sensorW : sensorH;
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: visualW <= 0 ? 720 : visualW,
            height: visualH <= 0 ? 1280 : visualH,
            child: Texture(textureId: config.textureId),
          ),
        ),
      ),
    );
  }

  Widget _topModeBar(CaptureMode? selected, CaptureCoordinator coordinator) {
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _ModeCard(
                label: 'Smart',
                icon: Icons.auto_awesome,
                selected: selected == null,
                onTap: () => _setMode(null, coordinator),
              ),
              for (final mode in CaptureMode.values)
                _ModeCard(
                  label: mode.label,
                  icon: mode.icon,
                  selected: selected == mode,
                  onTap: () => _setMode(mode, coordinator),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _setMode(CaptureMode? mode, CaptureCoordinator coordinator) {
    ref.read(selectedModeProvider.notifier).state = mode;
    coordinator.setMode(mode);
  }

  Future<void> _confirmFinish() async {
    final coordinator = ref.read(captureCoordinatorProvider);
    if (!coordinator.hasPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No photos captured yet')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Finish scan?'),
        content: const Text(
            'We will clean duplicates and export in the background.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Add more'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (ok == true) await _finish();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final coordinator = ref.read(captureCoordinatorProvider);
    await coordinator.finish();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          mode: coordinator.mode,
          shots: coordinator.shots,
          coverage: ref.read(coverageTrackerProvider).coveragePercent / 100.0,
          coverageMap: ref.read(coverageTrackerProvider).toJson(),
          perCameraCoverage:
              ref.read(coverageTrackerProvider).perCameraCoverage,
          dedupedCount: coordinator.dedupedCount,
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: InkWell(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? Colors.white70 : Colors.white24,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Material(
          color: Colors.white.withValues(alpha: 0.12),
          child: InkWell(
            onTap: onTap,
            child: Semantics(
              button: true,
              label: label,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CoveragePill extends StatelessWidget {
  const _CoveragePill({required this.percent});

  final double percent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        '${percent.round()}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _AutoFinishSheet extends StatelessWidget {
  const _AutoFinishSheet({
    required this.seconds,
    required this.onAddMore,
    required this.onFinish,
  });

  final int seconds;
  final VoidCallback onAddMore;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(18),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Scan complete. Export starts in $seconds',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              TextButton(onPressed: onAddMore, child: const Text('Add more')),
              FilledButton(onPressed: onFinish, child: const Text('Finish')),
            ],
          ),
        ),
      ),
    );
  }
}

class _BusyOverlay extends StatelessWidget {
  const _BusyOverlay({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(text, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }
}
