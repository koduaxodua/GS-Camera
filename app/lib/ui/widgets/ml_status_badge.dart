import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/embedding_service.dart';

/// Tiny pill in the HUD that tells the user which dedup path is active.
class MlStatusBadge extends StatefulWidget {
  const MlStatusBadge({super.key});

  @override
  State<MlStatusBadge> createState() => _MlStatusBadgeState();
}

class _MlStatusBadgeState extends State<MlStatusBadge> {
  Timer? _poll;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _refresh() {
    final ready = EmbeddingService.instance.isReady;
    final err = EmbeddingService.instance.initError;
    if (ready != _ready || err != _error) {
      setState(() {
        _ready = ready;
        _error = err;
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color dot;
    final String label;
    if (EmbeddingService.liveDedupEnabled) {
      if (_ready) {
        dot = Colors.lightGreenAccent;
        label = 'AI dedup on';
      } else if (_error != null) {
        dot = Colors.redAccent;
        label = 'AI dedup off';
      } else {
        dot = Colors.amberAccent;
        label = 'AI loading...';
      }
    } else if (EmbeddingService.postCaptureDedupEnabled) {
      dot = Colors.lightGreenAccent;
      label = 'AI cleanup';
    } else {
      dot = Colors.lightGreenAccent;
      label = 'Spatial dedup';
    }

    return Tooltip(
      message: _error ?? '',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
