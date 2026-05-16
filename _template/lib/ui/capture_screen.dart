import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/capture_coordinator.dart';
import '../models/capture_mode.dart';
import 'review_screen.dart';
import 'widgets/bubble_level.dart';
import 'widgets/coverage_sphere.dart';
import 'widgets/guidance_overlay.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.mode});
  final CaptureMode mode;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late final CaptureCoordinator coordinator;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    coordinator = CaptureCoordinator(mode: widget.mode);
    coordinator.start();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: coordinator,
        builder: (context, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final state = coordinator.state;
    if (state == CaptureState.idle ||
        state == CaptureState.preflight ||
        state == CaptureState.locking) {
      return const _CalibratingView();
    }
    if (state == CaptureState.guidance) {
      return _GuidanceFullScreen(coordinator: coordinator);
    }
    return _CapturingView(coordinator: coordinator, onFinish: _finish);
  }

  Future<void> _finish() async {
    await coordinator.finish();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ReviewScreen(
        mode: widget.mode,
        shots: coordinator.shots,
        coverage: coordinator.coverage.coverageFraction(),
      ),
    ));
  }
}

class _CalibratingView extends StatelessWidget {
  const _CalibratingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 18),
          Text('Calibrating camera…',
              style: TextStyle(color: Colors.white70, fontSize: 15)),
        ],
      ),
    );
  }
}

class _GuidanceFullScreen extends StatelessWidget {
  const _GuidanceFullScreen({required this.coordinator});
  final CaptureCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GuidanceOverlay(hint: coordinator.hint),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => coordinator.resumeAfterFix(),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Done', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _CapturingView extends StatelessWidget {
  const _CapturingView({required this.coordinator, required this.onFinish});
  final CaptureCoordinator coordinator;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final s = coordinator.lastSensor;
    final coveragePct =
        (coordinator.coverage.coverageFraction() * 100).round();
    final canFinish = coordinator.coverage.coverageFraction() >=
        coordinator.mode.minCoverageFraction;

    return Stack(
      children: [
        // The native camera plugin renders the preview into a surface beneath
        // the Flutter view; this is just our HUD overlay.
        Positioned.fill(child: Container(color: Colors.black)),

        // Top: guidance hint banner.
        Align(
          alignment: Alignment.topCenter,
          child: SafeArea(
            child: GuidanceOverlay(hint: coordinator.hint),
          ),
        ),

        // Top-right: coverage sphere.
        Positioned(
          top: 60,
          right: 16,
          child: CoverageSphereWidget(
            map: coordinator.coverage,
            azimuthDeg: s?.azimuthDeg ?? 0,
            elevationDeg: s?.elevationDeg ?? 0,
          ),
        ),

        // Top-left: bubble level (only visible when off-axis).
        Positioned(
          top: 60,
          left: 16,
          child: BubbleLevel(rollDeg: s?.rollDeg ?? 0),
        ),

        // Bottom: counters + Finish button.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _Stat('Photos', coordinator.shots.length.toString()),
                      _Stat('Coverage', '$coveragePct%'),
                      _Stat('Mode', coordinator.mode.label),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: canFinish ? onFinish : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: canFinish
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.18),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      child: Text(
                        canFinish
                            ? 'Finish'
                            : 'Keep capturing — ${(coordinator.mode.minCoverageFraction * 100).round()}% needed',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
        Text(label,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
      ],
    );
  }
}
