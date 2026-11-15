import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../application/walk_session_controller.dart';
import '../../domain/walk_math.dart';
import '../../domain/walk_models.dart';

/// Ring showing how far the walk is towards its goal, with done / target /
/// remaining and an estimate of the time left. Hidden for an open goal.
class GoalProgress extends StatelessWidget {
  const GoalProgress({super.key, required this.session, required this.now});
  final WalkSession session;
  final DateTime now;

  static String _fmt(GoalType t, double v, UnitSystem u) => switch (t) {
        GoalType.time => formatCompact(Duration(seconds: v.round())),
        GoalType.distance =>
          '${paceService.distanceIn(u, v).toStringAsFixed(2)} ${paceService.distanceUnit(u)}',
        GoalType.calories => '${v.round()} kcal',
        GoalType.steps => '${v.round()} steps',
        GoalType.open => '',
      };

  @override
  Widget build(BuildContext context) {
    final g = session.goal;
    if (g.isOpen) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final u = session.settings.units;
    final p = session.goalProgress(now);
    final done = p * g.target;
    final remaining = math.max(g.target - done, 0.0);

    // time left at the average rate so far
    final activeS = session.activeDuration(now).inSeconds;
    String? eta;
    if (!session.goalReached && activeS > 20 && done > 0) {
      final rate = done / activeS; // goal units per second
      eta = g.type == GoalType.time
          ? formatCompact(Duration(seconds: remaining.round()))
          : formatCompact(Duration(seconds: (remaining / rate).round()));
    }

    return Semantics(
      container: true,
      label: 'Goal ${(p * 100).round()} percent. ${_fmt(g.type, done, u)} of ${_fmt(g.type, g.target, u)}.',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(18)),
        child: Row(children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(alignment: Alignment.center, children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: p),
                duration: const Duration(milliseconds: 500),
                builder: (c, v, _) => CircularProgressIndicator(
                  value: v,
                  strokeWidth: 7,
                  strokeCap: StrokeCap.round,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: session.goalReached ? scheme.tertiary : scheme.primary,
                ),
              ),
              session.goalReached
                  ? Icon(Icons.emoji_events, color: scheme.tertiary)
                  : Text('${(p * 100).round()}%', style: text.labelLarge),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(session.goalReached ? 'Goal reached. Keep going if you like.' : '${g.type.label} goal',
                  style: text.titleSmall),
              const SizedBox(height: 2),
              Text('${_fmt(g.type, done, u)} of ${_fmt(g.type, g.target, u)}',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              if (!session.goalReached)
                Text(
                    '${_fmt(g.type, remaining, u)} to go'
                    '${eta == null ? '' : ' · about $eta'}',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}
