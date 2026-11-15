import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/walk_models.dart';

/// The large bottom controls of a walk: lock, pause/resume, finish and lap.
/// Every target is at least 56 px and labelled for screen readers.
class WalkControlBar extends StatelessWidget {
  const WalkControlBar({
    super.key,
    required this.status,
    required this.onPause,
    required this.onResume,
    required this.onFinish,
    required this.onLap,
    required this.onLock,
  });

  final WalkSessionStatus status;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onFinish;
  final VoidCallback onLap;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paused = status.isPaused;
    final recording = status.isRecording;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Small(icon: Icons.lock_outline, label: 'Lock screen', onTap: onLock),
            _Small(
                icon: Icons.flag_outlined,
                label: 'Add lap',
                onTap: recording
                    ? () {
                        HapticFeedback.mediumImpact();
                        onLap();
                      }
                    : null),
            Semantics(
              button: true,
              label: paused ? 'Resume walk' : 'Pause walk',
              child: SizedBox(
                width: 84,
                height: 84,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      backgroundColor: paused ? scheme.primary : scheme.surfaceContainerHighest,
                      foregroundColor: paused ? scheme.onPrimary : scheme.onSurface),
                  onPressed: paused || recording
                      ? () {
                          HapticFeedback.mediumImpact();
                          paused ? onResume() : onPause();
                        }
                      : null,
                  child: ExcludeSemantics(
                      child: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 44)),
                ),
              ),
            ),
            Semantics(
              button: true,
              label: 'Finish walk',
              child: SizedBox(
                width: 64,
                height: 64,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError),
                  onPressed: onFinish,
                  child: const ExcludeSemantics(child: Icon(Icons.stop_rounded, size: 34)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Small extends StatelessWidget {
  const _Small({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 56,
        height: 56,
        child: IconButton.filledTonal(tooltip: label, onPressed: onTap, icon: Icon(icon)),
      );
}

/// Covers the walk screen so a pocket cannot press anything. A deliberate
/// press-and-hold unlocks it.
class LockOverlay extends StatelessWidget {
  const LockOverlay({super.key, required this.onUnlock});
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        child: Center(
          child: Semantics(
            button: true,
            label: 'Screen locked. Press and hold to unlock.',
            child: GestureDetector(
              onLongPress: () {
                HapticFeedback.heavyImpact();
                onUnlock();
              },
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest),
                  child: Icon(Icons.lock, size: 40, color: scheme.onSurface),
                ),
                const SizedBox(height: 16),
                Text('Hold to unlock', style: Theme.of(context).textTheme.titleMedium),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
