import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/walk_session_controller.dart';
import '../../domain/walk_math.dart';
import '../../domain/walk_models.dart';
import '../walk_ui.dart';

/// Shown on every main screen while a walk exists (tracking, paused,
/// auto-paused, or finished but not yet saved). Tapping it returns to the
/// walk. It cannot be dismissed: only finishing or discarding removes it.
class WalkStatusBanner extends ConsumerWidget {
  const WalkStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild the frame only when the status changes; the numbers inside
    // listen for themselves.
    final status = ref.watch(walkStatusProvider);
    if (!status.isLive) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final paused = status.isPaused;
    final pending = status == WalkSessionStatus.awaitingSave || status == WalkSessionStatus.saving;
    final bg = pending
        ? scheme.tertiaryContainer
        : paused
            ? scheme.secondaryContainer
            : scheme.primary;
    final fg = pending
        ? scheme.onTertiaryContainer
        : paused
            ? scheme.onSecondaryContainer
            : scheme.onPrimary;
    final label = switch (status) {
      WalkSessionStatus.paused => 'Walk paused',
      WalkSessionStatus.autoPaused => 'Auto-paused',
      WalkSessionStatus.countingDown || WalkSessionStatus.preparing => 'Walk starting',
      WalkSessionStatus.awaitingSave || WalkSessionStatus.saving => 'Walk finished: save or discard',
      WalkSessionStatus.error => 'Walk needs attention',
      WalkSessionStatus.gpsWeak => 'Walk in progress · GPS weak',
      _ => 'Walk in progress',
    };
    void open() => ref.read(walkNavProvider).toWalk(context, ref.read(walkStatusProvider));

    return Semantics(
      container: true,
      button: true,
      label: '$label. Return to walk.',
      child: Material(
        color: bg,
        child: InkWell(
          onTap: open,
          child: SafeArea(
            bottom: false,
            top: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(children: [
                  Icon(paused ? Icons.pause_circle_outline : Icons.directions_walk, color: fg),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                        _BannerNumbers(color: fg),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExcludeSemantics(
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(48, 40),
                          backgroundColor: fg.withValues(alpha: 0.18),
                          foregroundColor: fg),
                      onPressed: paused
                          ? () {
                              ref.read(walkSessionProvider.notifier).resume();
                              open();
                            }
                          : open,
                      child: Text(pending ? 'Review' : (paused ? 'Resume' : 'Return to Walk')),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Elapsed time · distance · pace. Ticks by itself.
class _BannerNumbers extends ConsumerWidget {
  const _BannerNumbers({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(walkSessionProvider);
    if (s == null) return const SizedBox.shrink();
    return SecondTicker(builder: (context, now) {
      final u = s.settings.units;
      final active = s.activeDuration(now);
      final pace = paceService.formatPace(
          paceService.paceSeconds(u, paceService.averageSpeed(s.distanceM, active)));
      return Text(
        s.status == WalkSessionStatus.countingDown
            ? 'Starting in ${s.countdown}'
            : '${formatCompact(active)} · '
                '${paceService.distanceIn(u, s.distanceM).toStringAsFixed(2)} ${paceService.distanceUnit(u)} · '
                '${pace == '--' ? '${s.kcal.round()} kcal' : '$pace ${paceService.paceUnit(u)}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color, fontFeatures: const [FontFeature.tabularFigures()]),
      );
    });
  }
}

/// Small live badge for the Walk tab: a pulsing dot and the elapsed time.
/// Wrap the tab icon with it.
class WalkStatusChip extends ConsumerWidget {
  const WalkStatusChip({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(walkStatusProvider);
    if (!status.isLive) return child;
    final scheme = Theme.of(context).colorScheme;
    return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      child,
      Positioned(
        top: -10,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
              color: status.isPaused ? scheme.secondary : scheme.primary,
              borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _Pulse(active: status.isRecording, color: scheme.onPrimary),
            const SizedBox(width: 4),
            _ChipTime(color: status.isPaused ? scheme.onSecondary : scheme.onPrimary),
          ]),
        ),
      ),
    ]);
  }
}

class _ChipTime extends ConsumerWidget {
  const _ChipTime({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(walkSessionProvider);
    if (s == null) return const SizedBox.shrink();
    return SecondTicker(
      builder: (context, now) => Text(
        formatCompact(s.activeDuration(now)),
        semanticsLabel: 'Walk ${s.status.label}, ${formatCompact(s.activeDuration(now))}',
        style: TextStyle(
            fontSize: 10,
            height: 1.3,
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.active, required this.color});
  final bool active;
  final Color color;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Pulse old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    // Respect "reduce motion": a steady dot instead of a pulse.
    final animate = widget.active && !MediaQuery.disableAnimationsOf(context);
    if (animate && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!animate) {
      _c.stop();
      _c.value = 1; // a steady, fully visible dot
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
        child: Container(
            width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color)),
      );
}
