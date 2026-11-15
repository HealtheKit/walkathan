import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../application/walk_session_controller.dart';
import '../domain/walk_math.dart';
import '../domain/walk_models.dart';
import 'walk_ui.dart';
import 'widgets/walk_sheets.dart';

/// Before a walk: goal, GPS and feedback options, then Start.
class WalkSetupPage extends ConsumerStatefulWidget {
  const WalkSetupPage({super.key});

  @override
  ConsumerState<WalkSetupPage> createState() => _WalkSetupPageState();
}

class _WalkSetupPageState extends ConsumerState<WalkSetupPage> {
  WorkoutSettings _settings = const WorkoutSettings();
  GoalType _goal = GoalType.open;

  /// Goal amounts in the unit the user sees (min, km/mi, kcal, steps).
  final Map<GoalType, double> _amount = {
    GoalType.time: 30,
    GoalType.distance: 3,
    GoalType.calories: 200,
    GoalType.steps: 5000,
  };
  String _gps = 'checking';

  @override
  void initState() {
    super.initState();
    _checkGps();
  }

  Future<void> _checkGps() async {
    final s = await ref.read(locationServiceProvider).permissionStatus();
    if (mounted) setState(() => _gps = s);
  }

  Future<void> _allowGps() async {
    final s = await ref.read(locationServiceProvider).requestPermission();
    if (mounted) setState(() => _gps = s);
  }

  ({double step, double min, double max}) get _range => switch (_goal) {
        GoalType.time => (step: 5, min: 5, max: 300),
        GoalType.distance => (step: 0.5, min: 0.5, max: 50),
        GoalType.calories => (step: 25, min: 25, max: 2000),
        GoalType.steps => (step: 500, min: 500, max: 50000),
        GoalType.open => (step: 1, min: 0, max: 0),
      };

  /// Goal in SI units, as the session stores it.
  WorkoutGoal get _workoutGoal {
    final v = _amount[_goal] ?? 0;
    return switch (_goal) {
      GoalType.open => const WorkoutGoal(),
      GoalType.time => WorkoutGoal(type: _goal, target: v * 60),
      GoalType.distance =>
        WorkoutGoal(type: _goal, target: v * paceService.unitMetres(_settings.units)),
      _ => WorkoutGoal(type: _goal, target: v),
    };
  }

  /// Rough time to finish at an easy 5 km/h, 110 steps/min, 4 kcal/min.
  String? get _estimate {
    final g = _workoutGoal;
    if (g.isOpen) return null;
    final secs = switch (g.type) {
      GoalType.time => g.target,
      GoalType.distance => g.target / (5000 / 3600),
      GoalType.steps => g.target / 110 * 60,
      GoalType.calories => g.target / 4 * 60,
      GoalType.open => 0.0,
    };
    return formatCompact(Duration(seconds: secs.round()));
  }

  bool get _canStart => !_settings.useGps || _gps == 'granted';

  Future<void> _start() async {
    final c = ref.read(walkSessionProvider.notifier);
    if (!c.isReady) await c.ready; // a stored walk must be restored first
    if (!mounted) return;
    // INTEGRATION POINT (permissions): request activity-recognition / motion
    // and health permissions here before starting real sensors.
    final r = c.start(settings: _settings, goal: _workoutGoal);
    if (r == StartResult.alreadyActive) {
      await showDuplicateWalkDialog(context, ref);
      return;
    }
    ref.read(walkNavProvider).replaceWithActive(context);
  }

  @override
  Widget build(BuildContext context) {
    final nav = ref.read(walkNavProvider);
    final unit = _goal == GoalType.distance ? paceService.distanceUnit(_settings.units) : _goal.unit;
    final amount = _amount[_goal] ?? 0;
    final fmt = NumberFormat.decimalPattern();

    return WalkTheme(
      child: Builder(builder: (context) {
        // Read the theme INSIDE WalkTheme so colours are the dark ones.
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        return Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: () => nav.back(context)),
            title: const Text('Walk'),
            actions: [
              IconButton(
                tooltip: 'Walk settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () async {
                  final s = await showWalkSettingsSheet(context, _settings);
                  if (s != null && mounted) setState(() => _settings = s);
                },
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (!_canStart)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('Allow location, or turn off "Use GPS route", to start.',
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center),
                  ),
                SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: FilledButton.icon(
                    onPressed: _canStart ? _start : null,
                    icon: const Icon(Icons.play_arrow_rounded, size: 28),
                    label: const Text('Start Walk', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text('Goal', style: text.titleMedium),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final g in GoalType.values)
                  ChoiceChip(
                    label: Text(g.label),
                    selected: _goal == g,
                    onSelected: (_) => setState(() => _goal = g),
                  ),
              ]),
              if (_goal != GoalType.open) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      IconButton.filledTonal(
                        tooltip: 'Less',
                        iconSize: 28,
                        onPressed: amount <= _range.min
                            ? null
                            : () => setState(() => _amount[_goal] = amount - _range.step),
                        icon: const Icon(Icons.remove),
                      ),
                      Semantics(
                        liveRegion: true,
                        label: 'Goal ${fmt.format(amount)} $unit',
                        excludeSemantics: true,
                        child: Column(children: [
                          Text(fmt.format(amount),
                              style: text.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
                          Text(unit, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'More',
                        iconSize: 28,
                        onPressed: amount >= _range.max
                            ? null
                            : () => setState(() => _amount[_goal] = amount + _range.step),
                        icon: const Icon(Icons.add),
                      ),
                    ]),
                    if (_estimate != null) ...[
                      const SizedBox(height: 8),
                      Text('About $_estimate at an easy pace',
                          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ]),
                ),
              ],
              const SizedBox(height: 20),
              Text('Location', style: text.titleMedium),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use GPS route'),
                subtitle: Text(_settings.useGps
                    ? switch (_gps) {
                        'granted' => 'GPS ready',
                        'checking' => 'Checking GPS…',
                        'serviceOff' => 'Location is switched off on this phone',
                        'deniedForever' => 'Location is blocked in the phone settings',
                        _ => 'Location permission needed',
                      }
                    : 'Distance and pace will be estimated from steps'),
                secondary: Icon(
                    !_settings.useGps
                        ? Icons.location_off_outlined
                        : _gps == 'granted'
                            ? Icons.gps_fixed
                            : Icons.gps_not_fixed,
                    color: _settings.useGps && _gps == 'granted' ? scheme.primary : scheme.onSurfaceVariant),
                value: _settings.useGps,
                onChanged: (v) => setState(() => _settings = _settings.copyWith(useGps: v)),
              ),
              if (_settings.useGps && _gps != 'granted' && _gps != 'checking')
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 8, children: [
                    FilledButton.tonal(onPressed: _allowGps, child: const Text('Allow location')),
                    TextButton(
                        onPressed: () => setState(() => _settings = _settings.copyWith(useGps: false)),
                        child: const Text('Walk without GPS')),
                  ]),
                ),
              const SizedBox(height: 12),
              Text('Feedback', style: text.titleMedium),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Voice coaching'),
                value: _settings.voiceCoaching,
                onChanged: (v) => setState(() => _settings = _settings.copyWith(voiceCoaching: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto pause when movement stops'),
                value: _settings.autoPause,
                onChanged: (v) => setState(() => _settings = _settings.copyWith(autoPause: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Heart-rate monitoring'),
                value: _settings.heartRate,
                onChanged: (v) => setState(() => _settings = _settings.copyWith(heartRate: v)),
              ),
              const _RecentWalks(),
            ],
          ),
        );
      }),
    );
  }
}

/// The last few saved walks.
class _RecentWalks extends ConsumerWidget {
  const _RecentWalks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walks = ref.watch(walkHistoryProvider).value ?? const <WalkWorkout>[];
    if (walks.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final df = DateFormat.MMMd().add_jm();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text('Recent walks', style: text.titleMedium),
      for (final w in walks.take(3))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.directions_walk),
          title: Text(w.session.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${df.format(w.session.startedAt)} · '
              '${paceService.distanceIn(w.session.settings.units, w.session.distanceM).toStringAsFixed(2)} '
              '${paceService.distanceUnit(w.session.settings.units)} · '
              '${formatCompact(Duration(milliseconds: w.session.activeMs))}'),
        ),
    ]);
  }
}
