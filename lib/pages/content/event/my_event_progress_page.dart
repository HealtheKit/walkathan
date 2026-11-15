import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../features/activity/step_providers.dart';
import '../../../features/events/event_models.dart';
import '../../../features/events/event_providers.dart';
import '../../../features/events/event_scoring.dart';
import '../../../models/custom_error.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/brand_animation.dart';
import '../../widgets/infographics.dart';
import '../../widgets/state_widgets.dart';

final _num = NumberFormat.decimalPattern();
final _day = DateFormat.MMMd();

/// One participant's event: progress, weekly view, trends, consistency,
/// timing, calendar, bests, milestones, badges and reward eligibility.
class MyEventProgressPage extends ConsumerWidget {
  const MyEventProgressPage({super.key, required this.event, this.now});
  final MemberEvent event;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(myEventStatsProvider(event.id));
    final live = ref.watch(stepTrackingProvider).value;
    final today = (now ?? DateTime.now)();

    return Scaffold(
      appBar: AppBar(title: Text(event.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: stats.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load your progress.',
          onRetry: () => ref.invalidate(myEventStatsProvider(event.id)),
        ),
        data: (s) {
          if (s == null) return const EmptyState(title: 'No profile');
          // Overlay today's live count (display only).
          final days = [...s.days];
          final liveSteps = live?.displaySteps ?? 0;
          final todayKey = DateTime(today.year, today.month, today.day);
          final i = days.indexWhere((d) => d.date == todayKey);
          if (liveSteps > 0 && !todayKey.isBefore(s.config.startsOn) && !todayKey.isAfter(s.config.endsOn)) {
            if (i < 0) {
              days.add(EventDayRecord(date: todayKey, steps: liveSteps));
            } else if (liveSteps > days[i].steps) {
              days[i] = EventDayRecord(
                  date: todayKey, steps: liveSteps, distanceM: days[i].distanceM,
                  kcal: days[i].kcal, hours: days[i].hours);
            }
          }
          final sc = EventScore.compute(s.config, days, today);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myEventStatsProvider(event.id)),
            child: PageContainer(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: AppSpacing.pagePadding,
                children: [
                  _Today(score: sc, today: todayKey, live: live?.today),
                  _Section('Event progress', _EventProgress(score: sc)),
                  _Section('This week', _Weekly(score: sc)),
                  _Section('Trend', _Trend(score: sc)),
                  _Section('Consistency', _Consistency(score: sc)),
                  _Section('Calendar', _Calendar(score: sc)),
                  _Section('Personal bests', _Bests(score: sc)),
                  _Section('Milestones', _Milestones(score: sc)),
                  _Section('Badges', _Badges(score: sc)),
                  _Section('Recognition', _Reward(score: sc, reward: s.reward)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.child);
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          child,
        ]),
      );
}

/// Label/value pairs in a two-column grid, without boxing each one.
class _Facts extends StatelessWidget {
  const _Facts(this.items);
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: LayoutBuilder(builder: (context, c) {
          final w = (c.maxWidth - AppSpacing.lg) / 2;
          return Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.md,
            children: [
              for (final (label, value) in items)
                SizedBox(
                  width: w,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(value,
                        style: text.titleMedium?.copyWith(fontFeatures: AppTheme.tabularFigures)),
                    Text(label,
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _Today extends StatelessWidget {
  const _Today({required this.score, required this.today, this.live});
  final EventScore score;
  final DateTime today;
  final dynamic live;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final steps = score.stepsOn(today);
    final target = score.config.dailyTarget;
    final p = target <= 0 ? 0.0 : (steps / target).clamp(0.0, 1.0);
    final rec = score.on(today);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(children: [
          ProgressRing(
            value: p,
            size: 96,
            stroke: 9,
            color: p >= 1 ? context.brand.success : scheme.primary,
            center: Text('${(p * 100).round()}%', style: text.titleMedium),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_num.format(steps)} steps today', style: text.titleLarge),
              Text('Target ${_num.format(target)}',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: AppSpacing.sm),
              Text(
                [
                  if (rec?.distanceM != null) '${(rec!.distanceM! / 1000).toStringAsFixed(2)} km',
                  '~${score.estimatedActiveMinutes(steps)} active min',
                  if (rec?.kcal != null) '${rec!.kcal} kcal',
                  'streak ${score.currentStreak}',
                ].join(' · '),
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _EventProgress extends StatelessWidget {
  const _EventProgress({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        ProgressRing(
          value: score.eventProgress,
          size: 88,
          stroke: 8,
          center: Text('${(score.eventProgress * 100).round()}%', style: text.titleMedium),
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Text(
            'Day ${score.daysCompleted} of ${score.config.totalDays} · '
            '${score.daysRemaining} ${score.daysRemaining == 1 ? 'day' : 'days'} left',
            style: text.titleMedium,
          ),
        ),
      ]),
      const SizedBox(height: AppSpacing.md),
      _Facts([
        ('total steps', _num.format(score.totalSteps)),
        ('distance', '${(score.totalDistanceM / 1000).toStringAsFixed(1)} km'),
        ('days completed', '${score.daysCompleted} of ${score.config.totalDays}'),
        ('days remaining', '${score.daysRemaining}'),
        ('event completed', '${(score.eventProgress * 100).round()}%'),
        ('daily average', _num.format(score.averageDaily)),
      ]),
    ]);
  }
}

class _Weekly extends StatelessWidget {
  const _Weekly({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final tw = score.thisWeek, lw = score.lastWeek;
    final diff = tw.total - lw.total;
    final change = lw.total == 0
        ? (tw.total == 0 ? 'no change' : 'new this week')
        : '${diff >= 0 ? '+' : '−'}${(100 * diff.abs() / lw.total).round()}% vs last week';
    String day(DateTime? d) => d == null ? '–' : '${DateFormat.E().format(d)} ${_num.format(score.stepsOn(d))}';
    return _Facts([
      ('weekly steps', _num.format(tw.total)),
      ('weekly average', _num.format(tw.average)),
      ('best day', day(tw.best)),
      ('lowest day', day(tw.worst)),
      ('compared with last week', change),
      ('last week', _num.format(lw.total)),
    ]);
  }
}

/// Daily bars with the cumulative total as a line.
class _Trend extends StatelessWidget {
  const _Trend({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final t = score.trend;
    if (t.isEmpty) {
      return Text('The trend appears once the event starts.',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
            label: 'Daily steps and cumulative total over ${t.length} days, '
                'reaching ${_num.format(t.last.cumulative)}.',
            excludeSemantics: true,
            child: SizedBox(
              height: 150,
              child: GrowIn(builder: (c, grow) => CustomPaint(
                painter: _TrendPainter(
                  progress: grow,
                  steps: [for (final x in t) x.steps],
                  cumulative: [for (final x in t) x.cumulative],
                  target: score.config.dailyTarget,
                  bar: scheme.primary,
                  met: context.brand.success,
                  line: context.brand.gold,
                  grid: scheme.outlineVariant,
                ),
              )),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_day.format(t.first.date), style: text.labelSmall),
            Text(_day.format(t.last.date), style: text.labelSmall),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: AppSpacing.lg, children: [
            _Key(color: scheme.primary, label: 'daily steps'),
            _Key(color: context.brand.gold, label: 'cumulative'),
          ]),
        ]),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    this.progress = 1,
    required this.steps,
    required this.cumulative,
    required this.target,
    required this.bar,
    required this.met,
    required this.line,
    required this.grid,
  });
  /// 0..1 entrance: bars rise and the line draws.
  final double progress;
  final List<int> steps;
  final List<int> cumulative;
  final int target;
  final Color bar, met, line, grid;

  @override
  void paint(Canvas canvas, Size size) {
    final n = steps.length;
    final maxBar = [...steps, target, 1].reduce((a, b) => a > b ? a : b).toDouble();
    final maxCum = (cumulative.isEmpty ? 1 : cumulative.last).clamp(1, 1 << 62).toDouble();
    final slot = size.width / n;
    final w = (slot * 0.6).clamp(1.0, 24.0);

    final gy = size.height - size.height * target / maxBar;
    canvas.drawLine(Offset(0, gy), Offset(size.width, gy), Paint()..color = grid..strokeWidth = 1);

    for (var i = 0; i < n; i++) {
      final h = size.height * steps[i] / maxBar * progress;
      final x = slot * i + (slot - w) / 2;
      canvas.drawRRect(
        RRect.fromRectAndCorners(Rect.fromLTWH(x, size.height - h, w, h),
            topLeft: const Radius.circular(3), topRight: const Radius.circular(3)),
        Paint()..color = steps[i] >= target ? met : bar,
      );
    }
    final path = Path();
    final shown = (n * progress).ceil().clamp(0, n);
    for (var i = 0; i < shown; i++) {
      final p = Offset(slot * i + slot / 2, size.height - size.height * cumulative[i] / maxCum);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, Paint()..color = line..strokeWidth = 2.5..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.progress != progress || old.steps != steps || old.cumulative != cumulative;
}

class _Consistency extends StatelessWidget {
  const _Consistency({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final timing = score.timingConsistency;
    final recovered = score.recoveredAfterMissed;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (recovered != null)
        Card(
          child: ListTile(
            leading: Icon(Icons.trending_up, color: context.brand.success),
            title: const Text('Back on track'),
            subtitle: Text('You\'re walking again after $recovered missed '
                '${recovered == 1 ? 'day' : 'days'}. Keep it going.'),
          ),
        ),
      _Facts([
        ('step consistency', '${score.stepConsistency} / 100'),
        ('active-day rate', '${(score.activeDayRate * 100).round()}%'),
        ('current streak', '${score.currentStreak} days'),
        ('longest streak', '${score.longestStreak} days'),
        ('usual start', score.usualStartHour == null ? '–' : hourLabel(score.usualStartHour!)),
        ('usual finish', score.usualEndHour == null ? '–' : hourLabel(score.usualEndHour!)),
        ('average walk', score.averageWalkHours == null
            ? '–' : '${score.averageWalkHours!.toStringAsFixed(1)} h'),
        ('timing consistency', timing == null ? 'needs 3 days' : '$timing%'),
      ]),
      const SizedBox(height: AppSpacing.sm),
      Text(
        'Timing consistency is how often you start within an hour of your '
        'usual time, whatever time that is. Step consistency is 100 when '
        'every day has the same steps.',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    ]);
  }
}

class _Calendar extends StatelessWidget {
  const _Calendar({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final brand = context.brand;
    final start = DateTime(score.config.startsOn.year, score.config.startsOn.month, score.config.startsOn.day);
    final lead = start.weekday - 1;
    final days = [
      for (var i = 0; i < score.config.totalDays; i++) DateTime(start.year, start.month, start.day + i),
    ];

    Color? fill(DayStatus s) => switch (s) {
          DayStatus.targetMet => brand.success,
          DayStatus.active => scheme.primaryContainer,
          DayStatus.low => brand.gold.withValues(alpha: .35),
          DayStatus.missed => scheme.errorContainer,
          DayStatus.future => null,
        };
    String word(DayStatus s) => switch (s) {
          DayStatus.targetMet => 'target met',
          DayStatus.active => 'active',
          DayStatus.low => 'low activity',
          DayStatus.missed => 'missed',
          DayStatus.future => 'upcoming',
        };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            for (final l in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(child: Text(l, textAlign: TextAlign.center, style: text.labelSmall)),
          ]),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < lead; i++) const SizedBox.shrink(),
              for (final d in days)
                Semantics(
                  label: '${DateFormat.MMMMd().format(d)}: ${word(score.statusOf(d))}, '
                      '${_num.format(score.stepsOn(d))} steps',
                  excludeSemantics: true,
                  child: Container(
                    margin: const EdgeInsets.all(3),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: fill(score.statusOf(d)),
                      shape: BoxShape.circle,
                      border: score.statusOf(d) == DayStatus.future
                          ? Border.all(color: scheme.outlineVariant)
                          : null,
                    ),
                    child: Text('${d.day}',
                        style: text.labelMedium?.copyWith(
                            color: score.statusOf(d) == DayStatus.targetMet
                                ? Colors.white
                                : scheme.onSurface)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: AppSpacing.md, runSpacing: 4, children: [
            _Key(color: brand.success, label: 'target met'),
            _Key(color: scheme.primaryContainer, label: 'active'),
            _Key(color: brand.gold.withValues(alpha: .35), label: 'low'),
            _Key(color: scheme.errorContainer, label: 'missed'),
            _Key(color: scheme.outlineVariant, label: 'upcoming'),
          ]),
        ]),
      ),
    );
  }
}

class _Bests extends StatelessWidget {
  const _Bests({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final best = score.bestDay;
    final pace = score.fastestPaceKmh;
    return _Facts([
      ('highest day', best.date == null ? '–' : '${_num.format(best.steps)} (${_day.format(best.date!)})'),
      ('best week', _num.format(score.bestWeekTotal)),
      ('longest walk', score.longestWalkHours == 0 ? '–' : '${score.longestWalkHours} h'),
      ('fastest pace (est.)', pace == null ? '–' : '${pace.toStringAsFixed(1)} km/h'),
    ]);
  }
}

class _Milestones extends StatelessWidget {
  const _Milestones({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final next = score.nextMilestone;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (next != null) ...[
            Text('${_num.format(next.steps - score.totalSteps)} steps to ${_num.format(next.steps)}',
                style: text.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: (score.totalSteps / next.steps).clamp(0.0, 1.0), minHeight: 8),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
            for (final m in score.milestones)
              Chip(
                avatar: Icon(m.reached ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 18, color: m.reached ? context.brand.success : scheme.outline),
                label: Text(_num.format(m.steps)),
              ),
          ]),
        ]),
      ),
    );
  }
}

class _Badges extends StatelessWidget {
  const _Badges({required this.score});
  final EventScore score;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Column(children: [
        for (final b in score.badges)
          ListTile(
            leading: b.earned
                ? const BrandAnimation(BrandAnimationKind.badgeUnlock, size: 40, semanticLabel: 'Earned')
                : Icon(Icons.lock_outline, color: scheme.outline),
            title: Text(b.title),
            subtitle: Text(b.description,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            trailing: b.earned ? const Text('Earned') : null,
          ),
      ]),
    );
  }
}

class _Reward extends StatelessWidget {
  const _Reward({required this.score, this.reward});
  final EventScore score;
  final ({String award, String status})? reward;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final c = score.config;
    final rules = [
      if (c.rewardMinSteps != null) '${_num.format(c.rewardMinSteps)} steps',
      if (c.rewardMinActivePct != null) 'active on ${c.rewardMinActivePct}% of days',
    ];
    final String line;
    if (reward != null) {
      line = '${reward!.award}: ${switch (reward!.status) {
        'delivered' => 'delivered',
        'awarded' => 'awarded',
        _ => 'selected',
      }}.';
    } else if (rules.isEmpty) {
      line = 'The organizers have not announced recognition rules yet.';
    } else if (score.rewardEligible) {
      line = 'You currently qualify for recognition (${rules.join(' and ')}).';
    } else {
      line = 'To qualify: ${rules.join(' and ')}.';
    }
    return Card(
      child: ListTile(
        leading: Icon(Icons.workspace_premium_outlined,
            color: reward != null || score.rewardEligible ? context.brand.gold : scheme.outline),
        title: Text(line, style: text.bodyLarge),
      ),
    );
  }
}
