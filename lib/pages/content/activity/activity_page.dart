import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/time/local_day.dart';
import '../../../features/activity/history_math.dart';
import '../../../features/activity/step_providers.dart';
import '../../../models/custom_error.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../../utils/app_snackbar.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/state_widgets.dart';

final _num = NumberFormat.decimalPattern();

/// History, calendar, streaks (with Rest Days), records, achievements and
/// monthly / yearly recaps for the active profile.
class ActivityPage extends ConsumerStatefulWidget {
  const ActivityPage({super.key, this.now});

  /// Injectable clock for tests.
  final DateTime Function()? now;

  @override
  ConsumerState<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends ConsumerState<ActivityPage> {
  HistoryPeriod _period = HistoryPeriod.week;
  late DateTime _anchor = _today;

  DateTime get _today => (widget.now ?? DateTime.now)();

  void _shift(int dir) {
    final next = shiftAnchor(_period, _anchor, dir);
    if (periodRange(_period, next).start.isAfter(startOfDay(_today))) return;
    setState(() => _anchor = next);
  }

  Future<void> _toggleRest(DateTime day, bool isRest) async {
    final profile = ref.read(activeProfileProvider).value;
    if (profile == null) return;
    final repo = ref.read(stepRepositoryProvider);
    try {
      if (isRest) {
        await repo.removeRestDay(profile.id, dateKey(day));
      } else {
        await repo.addRestDay(profile.id, dateKey(day));
      }
      ref.invalidate(activityHistoryProvider);
      if (mounted) {
        showAppSnackBar(context, isRest ? 'Rest day removed' : 'Rest day set');
      }
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  void _showDay(ActivityHistory h, DateTime day) {
    final rec = h.days[dateKey(day)];
    final isRest = h.isRest(day);
    final today = startOfDay(_today);
    // The server allows yesterday onward; the app offers today onward.
    final canToggle = !day.isBefore(today);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) {
        final text = Theme.of(c).textTheme;
        final scheme = Theme.of(c).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(DateFormat.yMMMMEEEEd().format(day), style: text.titleMedium),
                const SizedBox(height: AppSpacing.md),
                Text('${_num.format(rec?.steps ?? 0)} steps', style: text.headlineSmall),
                Text(
                  [
                    if (rec?.distanceM != null)
                      '${(rec!.distanceM! / 1000).toStringAsFixed(2)} km',
                    if (rec?.kcal != null) '${rec!.kcal} kcal',
                    if (rec?.floors != null) '${rec!.floors} floors',
                    if (h.metGoal(day)) 'goal reached',
                    if (isRest) 'rest day',
                  ].join(' · '),
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (canToggle) ...[
                  const SizedBox(height: AppSpacing.lg),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(c);
                      _toggleRest(day, isRest);
                    },
                    icon: Icon(isRest ? Icons.close : Icons.hotel_outlined),
                    label: Text(isRest ? 'Remove rest day' : 'Make this a rest day'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'A rest day keeps your streak going without walking. '
                    'Up to $kMaxRestDaysPerWeek per week.',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(activityHistoryProvider);
    final live = ref.watch(stepTrackingProvider).value?.today;
    final today = _today;

    return AppShell(
      current: AppTab.activity,
      title: 'Activity',
      onRefresh: () => ref.invalidate(activityHistoryProvider),
      body: history.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load your history.',
          onRetry: () => ref.invalidate(activityHistoryProvider),
        ),
        data: (raw) {
          if (raw == null) {
            return const EmptyState(
                title: 'No profile', message: 'Add a profile to see activity.');
          }
          // Show today's live count even before it has uploaded.
          final h = raw.withLive(
            today,
            live == null || live.localDate != dateKey(today)
                ? null
                : DayRecord(
                    steps: live.steps,
                    distanceM: live.distanceM,
                    kcal: live.kcal,
                    floors: live.floors),
          );
          final summary = summarize(h, _period, _anchor, today);
          final streak = computeStreak(h, today);
          final records = computeRecords(h, today);
          final achievements = computeAchievements(h, today);
          final month = summarize(h, HistoryPeriod.month, _anchor, today);
          final year = summarize(h, HistoryPeriod.year, _anchor, today);

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(activityHistoryProvider),
            child: PageContainer(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: AppSpacing.pagePadding,
                children: [
                  SegmentedButton<HistoryPeriod>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: HistoryPeriod.day, label: Text('Day')),
                      ButtonSegment(value: HistoryPeriod.week, label: Text('Week')),
                      ButtonSegment(value: HistoryPeriod.month, label: Text('Month')),
                      ButtonSegment(value: HistoryPeriod.year, label: Text('Year')),
                    ],
                    selected: {_period},
                    onSelectionChanged: (s) => setState(() => _period = s.first),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _PeriodCard(
                    period: _period,
                    anchor: _anchor,
                    summary: summary,
                    goal: h.goal,
                    canGoForward: !periodRange(_period, shiftAnchor(_period, _anchor, 1))
                        .start
                        .isAfter(startOfDay(today)),
                    onShift: _shift,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _StreakCard(streak: streak, restUsed: restDaysInWeek(h, today)),
                  const SizedBox(height: AppSpacing.lg),
                  _CalendarCard(
                    history: h,
                    month: DateTime(_anchor.year, _anchor.month, 1),
                    today: today,
                    onDayTap: (d) => _showDay(h, d),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _RecapCard(
                    title: '${DateFormat.yMMMM().format(_anchor)} recap',
                    summary: month,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _RecapCard(title: '${_anchor.year} recap', summary: year),
                  const SizedBox(height: AppSpacing.lg),
                  _RecordsCard(records: records),
                  const SizedBox(height: AppSpacing.lg),
                  _AchievementsCard(achievements: achievements),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _periodTitle(HistoryPeriod p, DateTime anchor) {
  final r = periodRange(p, anchor);
  return switch (p) {
    HistoryPeriod.day => DateFormat.yMMMEd().format(anchor),
    HistoryPeriod.week =>
      '${DateFormat.MMMd().format(r.start)} – ${DateFormat.MMMd().format(r.end)}',
    HistoryPeriod.month => DateFormat.yMMMM().format(anchor),
    HistoryPeriod.year => '${anchor.year}',
  };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.icon});
  final String title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
      ]),
    );
  }
}

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    required this.period,
    required this.anchor,
    required this.summary,
    required this.goal,
    required this.canGoForward,
    required this.onShift,
  });

  final HistoryPeriod period;
  final DateTime anchor;
  final PeriodSummary summary;
  final int goal;
  final bool canGoForward;
  final void Function(int dir) onShift;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isDay = period == HistoryPeriod.day;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous',
                  onPressed: () => onShift(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(_periodTitle(period, anchor),
                      textAlign: TextAlign.center, style: text.titleMedium),
                ),
                IconButton(
                  tooltip: 'Next',
                  onPressed: canGoForward ? () => onShift(1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _num.format(summary.total),
                style: text.displaySmall?.copyWith(
                    color: scheme.primary, fontFeatures: AppTheme.tabularFigures),
              ),
            ),
            Text(
              isDay
                  ? 'steps · goal ${_num.format(goal)}'
                  : 'steps · ${_num.format(summary.dailyAverage)} a day on average',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (!isDay) ...[
              const SizedBox(height: AppSpacing.lg),
              _BarChart(
                points: summary.points,
                // The goal line only makes sense for per-day bars.
                goal: period == HistoryPeriod.year ? null : goal,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.xs,
              children: [
                Text('${(summary.distanceM / 1000).toStringAsFixed(1)} km',
                    style: text.bodyMedium),
                Text('${_num.format(summary.kcal)} kcal', style: text.bodyMedium),
                if (!isDay)
                  Text('goal met ${summary.goalsMet}×', style: text.bodyMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.points, this.goal});
  final List<SeriesPoint> points;
  final int? goal;

  static const double _height = 140;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final brand = context.brand;
    var maxV = goal ?? 0;
    for (final p in points) {
      if (p.steps > maxV) maxV = p.steps;
    }
    if (maxV <= 0) maxV = 1;
    final dense = points.length > 12;

    return Semantics(
      label: 'Bar chart of steps. '
          '${points.where((p) => p.steps > 0).length} of ${points.length} bars have steps.',
      excludeSemantics: true,
      child: Column(
        children: [
          SizedBox(
            height: _height,
            child: Stack(
              children: [
                if (goal != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: _height * goal! / maxV - 0.5,
                    child: Container(height: 1, color: scheme.outline),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final p in points)
                      Expanded(
                        child: Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: dense ? 1 : 4),
                          child: Container(
                            height: p.steps <= 0
                                ? 2
                                : (_height * p.steps / maxV).clamp(2, _height),
                            decoration: BoxDecoration(
                              color: p.steps <= 0
                                  ? scheme.surfaceContainerHighest
                                  : (goal != null && p.steps >= goal!)
                                      ? brand.success
                                      : scheme.primary,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(4)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final p in points)
                Expanded(
                  child: Text(
                    p.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: text.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.streak, required this.restUsed});
  final StreakInfo streak;
  final int restUsed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: context.brand.gold.withValues(alpha: .18),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.local_fire_department, color: context.brand.gold),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current streak: ${streak.current} '
                    '${streak.current == 1 ? 'day' : 'days'}',
                    style: text.titleLarge,
                  ),
                  Text(
                    'Best ${streak.best} · rest days this week '
                    '$restUsed/$kMaxRestDaysPerWeek',
                    style: text.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarCard extends StatelessWidget {
  const _CalendarCard({
    required this.history,
    required this.month,
    required this.today,
    required this.onDayTap,
  });

  final ActivityHistory history;
  final DateTime month;
  final DateTime today;
  final void Function(DateTime) onDayTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final brand = context.brand;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final lead = DateTime(month.year, month.month, 1).weekday - 1; // Monday first
    final t = startOfDay(today);

    Widget cell(int dayNum) {
      final d = DateTime(month.year, month.month, dayNum);
      final met = history.metGoal(d);
      final rest = history.isRest(d);
      final steps = history.stepsOn(d);
      final isToday = d == t;
      final future = d.isAfter(t);

      Color? fill;
      Color fg = future ? scheme.onSurfaceVariant.withValues(alpha: .5) : scheme.onSurface;
      if (met) {
        fill = brand.success;
        fg = Colors.white;
      } else if (rest) {
        fill = scheme.surfaceContainerHighest;
      } else if (steps > 0) {
        fill = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
      }

      return Semantics(
        button: true,
        label: '${DateFormat.MMMMd().format(d)}: ${_num.format(steps)} steps'
            '${met ? ', goal reached' : ''}${rest ? ', rest day' : ''}',
        excludeSemantics: true,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => onDayTap(d),
          child: Container(
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: isToday
                  ? Border.all(color: scheme.primary, width: 2)
                  : null,
            ),
            alignment: Alignment.center,
            child: rest && !met
                ? Icon(Icons.hotel_outlined, size: 16, color: scheme.onSurfaceVariant)
                : Text('$dayNum',
                    style: text.labelMedium?.copyWith(color: fg)),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(DateFormat.yMMMM().format(month),
                icon: Icons.calendar_month_outlined),
            Row(
              children: [
                for (final l in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                  Expanded(
                    child: Text(l,
                        textAlign: TextAlign.center,
                        style: text.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < lead; i++) const SizedBox.shrink(),
                for (var d = 1; d <= daysInMonth; d++) cell(d),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.lg,
              runSpacing: 4,
              children: [
                _Legend(color: brand.success, label: 'Goal reached'),
                _Legend(color: scheme.primaryContainer, label: 'Some steps'),
                _Legend(color: scheme.surfaceContainerHighest, label: 'Rest day'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Flexible(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}

class _RecapCard extends StatelessWidget {
  const _RecapCard({required this.title, required this.summary});
  final String title;
  final PeriodSummary summary;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget stat(String value, String label) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: text.titleMedium),
              ),
              Text(label,
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(title, icon: Icons.auto_awesome_outlined),
            if (summary.total == 0)
              Text('No steps recorded in this period yet.',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant))
            else ...[
              Row(children: [
                stat(_num.format(summary.total), 'total steps'),
                stat(_num.format(summary.dailyAverage), 'daily average'),
                stat('${summary.goalsMet}', 'goals reached'),
              ]),
              const SizedBox(height: AppSpacing.md),
              Row(children: [
                stat('${(summary.distanceM / 1000).toStringAsFixed(1)} km', 'distance'),
                stat(_num.format(summary.kcal), 'kcal'),
                stat(
                  summary.bestDay == null
                      ? '–'
                      : _num.format(summary.bestDaySteps),
                  summary.bestDay == null
                      ? 'best day'
                      : 'best day, ${DateFormat.MMMd().format(summary.bestDay!)}',
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecordsCard extends StatelessWidget {
  const _RecordsCard({required this.records});
  final PersonalRecords records;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget row(IconData icon, String label, String value, String? when) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: text.bodyMedium),
                  if (when != null)
                    Text(when,
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            Text(value,
                style: text.titleMedium
                    ?.copyWith(fontFeatures: AppTheme.tabularFigures)),
          ]),
        );

    String? fmt(DateTime? d, DateFormat f) => d == null ? null : f.format(d);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle('Personal records', icon: Icons.military_tech_outlined),
            row(Icons.today, 'Best day', _num.format(records.bestDaySteps),
                fmt(records.bestDay, DateFormat.yMMMd())),
            row(Icons.view_week_outlined, 'Best week',
                _num.format(records.bestWeekSteps),
                records.bestWeekStart == null
                    ? null
                    : 'week of ${DateFormat.yMMMd().format(records.bestWeekStart!)}'),
            row(Icons.calendar_month_outlined, 'Best month',
                _num.format(records.bestMonthSteps),
                fmt(records.bestMonth, DateFormat.yMMMM())),
            row(Icons.local_fire_department_outlined, 'Longest streak',
                '${records.bestStreak} days', null),
          ],
        ),
      ),
    );
  }
}

class _AchievementsCard extends StatelessWidget {
  const _AchievementsCard({required this.achievements});
  final List<Achievement> achievements;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final brand = context.brand;
    final earned = achievements.where((a) => a.earned).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle('Achievements · $earned of ${achievements.length}',
                icon: Icons.emoji_events_outlined),
            for (final a in achievements)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Semantics(
                  label: '${a.title}. ${a.description}. '
                      '${a.earned ? 'Earned' : '${(a.progress * 100).round()} percent'}',
                  excludeSemantics: true,
                  child: Row(children: [
                    Icon(
                      a.earned ? Icons.verified : Icons.radio_button_unchecked,
                      color: a.earned ? brand.gold : scheme.outline,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.title, style: text.bodyLarge),
                          Text(a.description,
                              style: text.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                          if (!a.earned) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                  value: a.progress, minHeight: 6),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
