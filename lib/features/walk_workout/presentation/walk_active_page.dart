import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/walk_session_controller.dart';
import '../domain/walk_math.dart';
import '../domain/walk_models.dart';
import 'walk_ui.dart';
import 'widgets/control_bar.dart';
import 'widgets/goal_progress.dart';
import 'widgets/live_chart.dart';
import 'widgets/metric_card.dart';
import 'widgets/route_view.dart';
import 'widgets/walk_sheets.dart';

/// The live walk. Built entirely from the app-wide session, so leaving and
/// coming back (or the screen being rebuilt after the app was closed) shows
/// exactly the same walk.
class WalkActivePage extends ConsumerStatefulWidget {
  const WalkActivePage({super.key});

  @override
  ConsumerState<WalkActivePage> createState() => _WalkActivePageState();
}

class _WalkActivePageState extends ConsumerState<WalkActivePage> {
  bool _locked = false;

  WalkSessionController get _c => ref.read(walkSessionProvider.notifier);

  Future<void> _finish() async {
    final choice = await showFinishSheet(context);
    if (!mounted || choice == null) return;
    switch (choice) {
      case FinishChoice.resume:
        _c.resume();
      case FinishChoice.finish:
        await _c.finish();
        if (mounted) ref.read(walkNavProvider).replaceWithSummary(context);
      case FinishChoice.discard:
        if (await confirmDiscard(context)) {
          await _c.discard();
          if (mounted) ref.read(walkNavProvider).home(context);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Buzz on each countdown number and when the goal is reached.
    ref.listen(walkSessionProvider.select((s) => s?.countdown), (prev, next) {
      if (next != null && next > 0 && next != prev) HapticFeedback.selectionClick();
    });
    ref.listen(walkSessionProvider.select((s) => s?.goalReached ?? false), (prev, next) {
      if (next && prev == false) HapticFeedback.heavyImpact();
    });
    // A finished walk belongs on the summary screen.
    ref.listen(walkStatusProvider, (prev, next) {
      if (next == WalkSessionStatus.awaitingSave && prev != WalkSessionStatus.awaitingSave && mounted) {
        ref.read(walkNavProvider).replaceWithSummary(context);
      }
    });

    final session = ref.watch(walkSessionProvider);
    final nav = ref.read(walkNavProvider);

    return WalkTheme(
      child: Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;

        if (session == null) {
          return Scaffold(
            appBar: AppBar(leading: BackButton(onPressed: () => nav.back(context)), title: const Text('Walk')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.directions_walk, size: 56, color: scheme.onSurfaceVariant),
                  const SizedBox(height: 12),
                  Text('No walk in progress', style: text.titleLarge),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: () => nav.toSetup(context), child: const Text('Start a walk')),
                ]),
              ),
            ),
          );
        }
        if (session.status == WalkSessionStatus.awaitingSave || session.status == WalkSessionStatus.saving) {
          return Scaffold(
            body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (session.status == WalkSessionStatus.saving) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('Saving workout…', style: text.titleMedium),
                ] else ...[
                  Icon(Icons.flag_circle_outlined, size: 56, color: scheme.primary),
                  const SizedBox(height: 12),
                  Text('Walk finished', style: text.titleLarge),
                ],
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: () => nav.replaceWithSummary(context), child: const Text('Review walk')),
              ]),
            ),
          );
        }

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Stack(children: [
              Column(children: [
                _TopBar(
                  session: session,
                  onBack: () => nav.back(context),
                  onSettings: () async {
                    final s = await showWalkSettingsSheet(context, session.settings, duringWalk: true);
                    if (s != null) _c.setUnits(s.units);
                  },
                ),
                Expanded(child: SecondTicker(builder: (context, now) => _Body(session: session, now: now))),
                WalkControlBar(
                  status: session.status,
                  onPause: _c.pause,
                  onResume: _c.resume,
                  onFinish: _finish,
                  onLap: _c.addLap,
                  onLock: () => setState(() => _locked = true),
                ),
              ]),
              if (_locked) LockOverlay(onUnlock: () => setState(() => _locked = false)),
              if (session.status == WalkSessionStatus.countingDown)
                _Countdown(seconds: session.countdown, onSkip: _c.skipCountdown, onCancel: () async {
                  await _c.discard();
                  if (context.mounted) nav.back(context);
                }),
            ]),
          ),
        );
      }),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.session, required this.onBack, required this.onSettings});
  final WalkSession session;
  final VoidCallback onBack;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = session;
    final statusColor = switch (s.status) {
      WalkSessionStatus.tracking => scheme.primary,
      WalkSessionStatus.gpsWeak => scheme.tertiary,
      WalkSessionStatus.error => scheme.error,
      _ => scheme.secondary,
    };
    final gps = !s.settings.useGps
        ? (Icons.location_off_outlined, 'GPS off', scheme.onSurfaceVariant)
        : s.gpsAccuracyM == null
            ? (Icons.gps_not_fixed, 'Waiting for GPS signal', scheme.tertiary)
            : s.gpsAccuracyM! > 30
                ? (Icons.gps_not_fixed, 'GPS weak, ${s.gpsAccuracyM!.round()} metres', scheme.tertiary)
                : (Icons.gps_fixed, 'GPS good, ${s.gpsAccuracyM!.round()} metres', scheme.primary);
    final hr = !s.settings.heartRate
        ? (Icons.heart_broken_outlined, 'Heart rate off', scheme.onSurfaceVariant)
        : s.currentHr == null
            ? (Icons.favorite_border, 'Heart rate: measuring', scheme.onSurfaceVariant)
            : (Icons.favorite, 'Heart rate sensor connected', scheme.error);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Row(children: [
        IconButton(tooltip: 'Back (the walk keeps running)', onPressed: onBack, icon: const Icon(Icons.expand_more)),
        Flexible(
            child: Semantics(
          liveRegion: true,
          label: 'Status: ${s.status.label}',
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(s.status.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: statusColor, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        )),
        const SizedBox(width: 8),
        const Spacer(),
        Tooltip(message: gps.$2, child: Semantics(label: gps.$2, child: Icon(gps.$1, color: gps.$3, size: 22))),
        const SizedBox(width: 12),
        Tooltip(message: hr.$2, child: Semantics(label: hr.$2, child: Icon(hr.$1, color: hr.$3, size: 22))),
        IconButton(tooltip: 'More options', onPressed: onSettings, icon: const Icon(Icons.more_vert)),
      ]),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.session, required this.now});
  final WalkSession session;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = session;
    final u = s.settings.units;
    final active = s.activeDuration(now);
    final avgSpeed = paceService.averageSpeed(s.distanceM, active);
    final profile = ProviderScope.containerOf(context).read(walkUserProfileProvider);
    final zone = s.currentHr == null ? null : heartRateZone(s.currentHr!, profile.maxHeartRate);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      children: [
        // ---- primary: duration and distance
        Semantics(
          label: 'Duration ${active.inHours} hours ${active.inMinutes % 60} minutes ${active.inSeconds % 60} seconds',
          excludeSemantics: true,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(formatDuration(active),
                  style: text.displayLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: s.status.isPaused ? scheme.onSurfaceVariant : scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ),
        ),
        if (s.status.isPaused)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(children: [
              Text(
                  s.autoPauseReason ??
                      (s.status == WalkSessionStatus.autoPaused ? 'Auto-paused' : 'Paused'),
                  style: text.titleSmall?.copyWith(color: scheme.secondary),
                  textAlign: TextAlign.center),
              Text('Paused for ${formatCompact(s.pausedDuration(now))} · total ${formatCompact(s.totalDuration(now))}',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        if (s.status == WalkSessionStatus.gpsWeak)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('GPS signal is weak. Your walk is still being recorded from your steps.',
                style: text.bodySmall?.copyWith(color: scheme.tertiary), textAlign: TextAlign.center),
          ),
        if (s.status == WalkSessionStatus.error)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(s.errorMessage ?? 'Something went wrong. You can finish or discard this walk.',
                style: text.bodySmall?.copyWith(color: scheme.error), textAlign: TextAlign.center),
          ),
        Row(children: [
          Expanded(
            flex: 3,
            child: MetricCard(
              label: 'Distance',
              value: paceService.distanceIn(u, s.distanceM).toStringAsFixed(s.distanceM < 10000 ? 2 : 1),
              unit: paceService.distanceUnit(u),
              large: true,
              accent: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: MetricCard(
              label: 'Pace',
              value: paceService.formatPace(paceService.paceSeconds(u, s.currentSpeed)),
              unit: paceService.paceUnit(u),
              caption: 'avg ${paceService.formatPace(paceService.paceSeconds(u, avgSpeed))}',
              large: true,
            ),
          ),
        ]),
        const SizedBox(height: 10),
        if (!s.goal.isOpen) ...[
          GoalProgress(session: s, now: now),
          const SizedBox(height: 10),
        ],
        // ---- secondary metrics
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= 520 ? 4 : 2;
          final w = (c.maxWidth - 10 * (cols - 1)) / cols;
          final cards = [
            MetricCard(
                label: 'Calories', value: '${s.kcal.round()}', unit: 'kcal', icon: Icons.local_fire_department_outlined),
            MetricCard(
                label: 'Steps',
                value: '${s.steps}',
                icon: Icons.directions_walk,
                caption: s.cadence > 0 ? '${s.cadence} steps/min' : null),
            MetricCard(
                label: 'Heart rate',
                value: !s.settings.heartRate ? '--' : (s.currentHr?.toString() ?? '--'),
                unit: 'bpm',
                icon: Icons.favorite_border,
                accent: s.currentHr == null ? null : scheme.error,
                caption: !s.settings.heartRate
                    ? 'Off'
                    : s.currentHr == null
                        ? 'Measuring…'
                        : '${kHeartRateZones[zone!]} zone'),
            MetricCard(
                label: 'Speed',
                value: paceService.speedIn(u, s.currentSpeed).toStringAsFixed(1),
                unit: paceService.speedUnit(u),
                icon: Icons.speed,
                caption: 'avg ${paceService.speedIn(u, avgSpeed).toStringAsFixed(1)}'),
            MetricCard(
                label: 'Cadence',
                value: s.cadence > 0 ? '${s.cadence}' : '--',
                unit: 'spm',
                icon: Icons.graphic_eq,
                caption: active.inSeconds > 30
                    ? 'avg ${(s.steps / (active.inSeconds / 60)).round()}'
                    : null),
            MetricCard(
                label: 'Elevation',
                value: s.altitude == null ? '--' : '+${s.elevGain.round()}',
                unit: 'm',
                icon: Icons.terrain_outlined,
                caption: s.altitude == null
                    ? 'No altitude data'
                    : '-${s.elevLoss.round()} m · now ${s.altitude!.round()} m'),
          ];
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final card in cards) SizedBox(width: w, child: card),
          ]);
        }),
        const SizedBox(height: 10),
        RouteView(points: s.route, gpsOn: s.settings.useGps),
        const SizedBox(height: 10),
        LiveChart(series: s.series, units: u),
        if (s.laps.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Laps', style: text.titleSmall),
          for (final l in s.laps.reversed.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'Lap ${l.index} · ${formatCompact(Duration(milliseconds: l.durationMs))} · '
                  '${paceService.distanceIn(u, l.distanceM).toStringAsFixed(2)} ${paceService.distanceUnit(u)} · '
                  '${l.kcal.round()} kcal',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
        ],
        if (s.settings.musicControls) ...[
          const SizedBox(height: 10),
          // INTEGRATION POINT (music): wire these to the platform media session.
          Container(
            decoration:
                BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: const [
              IconButton(tooltip: 'Previous track', onPressed: null, icon: Icon(Icons.skip_previous)),
              IconButton(tooltip: 'Play or pause music', onPressed: null, icon: Icon(Icons.play_arrow)),
              IconButton(tooltip: 'Next track', onPressed: null, icon: Icon(Icons.skip_next)),
            ]),
          ),
        ],
      ],
    );
  }
}

/// 3 · 2 · 1 with "Skip countdown".
class _Countdown extends StatelessWidget {
  const _Countdown({required this.seconds, required this.onSkip, required this.onCancel});
  final int seconds;
  final VoidCallback onSkip;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Positioned.fill(
      child: Material(
        color: scheme.surface.withValues(alpha: 0.96),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('Get ready', style: text.titleLarge?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            label: 'Starting in $seconds',
            excludeSemantics: true,
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 250),
              transitionBuilder: (child, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: child)),
              child: Text('$seconds',
                  key: ValueKey(seconds),
                  style: TextStyle(fontSize: 150, height: 1, fontWeight: FontWeight.w800, color: scheme.primary)),
            ),
          ),
          const SizedBox(height: 28),
          SizedBox(
            height: 52,
            child: FilledButton.tonal(onPressed: onSkip, child: const Text('Skip countdown')),
          ),
          const SizedBox(height: 8),
          SizedBox(height: 48, child: TextButton(onPressed: onCancel, child: const Text('Cancel'))),
        ]),
      ),
    );
  }
}
