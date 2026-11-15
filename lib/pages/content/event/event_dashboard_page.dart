import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:go_router/go_router.dart';

import '../../../config/router/route_names.dart';
import '../../../features/events/event_models.dart';
import '../../../providers/profile_providers.dart';
import 'my_event_progress_page.dart';
import '../../../features/events/event_providers.dart';
import '../../../models/custom_error.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/brand_animation.dart';
import '../../widgets/infographics.dart';
import '../../widgets/state_widgets.dart';
import '../leader_board/leaderboard_widgets.dart';

final _num = NumberFormat.decimalPattern();
final _compact = NumberFormat.compact();
final _day = DateFormat.MMMd();

/// The event dashboard: where the walkathon stands and who is leading.
class EventDashboardPage extends ConsumerStatefulWidget {
  const EventDashboardPage({super.key, this.now});

  /// Injectable clock for tests.
  final DateTime Function()? now;

  @override
  ConsumerState<EventDashboardPage> createState() => _EventDashboardPageState();
}

class _EventDashboardPageState extends ConsumerState<EventDashboardPage> {
  BoardPeriod _period = BoardPeriod.event;
  BoardMetric _metric = BoardMetric.steps;
  BoardCohort _cohort = BoardCohort.all;
  Timer? _timer;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    // Boards change as people walk: refresh quietly once a minute.
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(eventBoardProvider);
  }

  Future<void> _pickEvent(List<MemberEvent> events, String currentId) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final e in events)
              ListTile(
                title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(_statusLine(e, _now)),
                trailing: e.id == currentId ? const Icon(Icons.check) : null,
                onTap: () {
                  ref.read(selectedEventIdProvider.notifier).select(e.id);
                  Navigator.pop(c);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(myEventsProvider);
    final current = ref.watch(currentEventProvider);

    return AppShell(
      current: AppTab.leaderboard,
      title: 'Event',
      onRefresh: () {
        ref.invalidate(myEventsProvider);
        ref.invalidate(eventBoardProvider);
      },
      body: current.when(
        loading: () => const PageContainer(child: _DashboardSkeleton()),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load your events.',
          onRetry: () => ref.invalidate(myEventsProvider),
        ),
        data: (event) {
          if (event == null) {
            return const EmptyState(
              icon: Icons.event_outlined,
              animation: BrandAnimationKind.walker,
              title: 'You\'re not on an event yet',
              message:
                  'Your walkathon administrator adds members to each event. '
                  'Once you\'re added, the board appears here. Your steps are '
                  'already being counted in the meantime.',
            );
          }
          final key = boardKey(event.id, _period, metric: _metric, cohort: _cohort);
          final board = ref.watch(eventBoardProvider(key));
          final all = events.value ?? [event];

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(eventBoardProvider);
              try {
                await ref.read(eventBoardProvider(key).future);
              } catch (_) {/* shown in the board's own error state */}
            },
            child: PageContainer(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: AppSpacing.pagePadding,
                children: [
                  _EventHeader(
                    event: event,
                    now: _now,
                    onSwitch: all.length > 1 ? () => _pickEvent(all, event.id) : null,
                  ),
                  _StatusNotices(event: event, board: board.value),
                  const SizedBox(height: AppSpacing.xl),
                  _StatStrip(board: board.value, loading: board.isLoading),
                  const SizedBox(height: AppSpacing.lg),
                  _Standing(board: board.value, metric: _metric),
                  const SizedBox(height: AppSpacing.md),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => MyEventProgressPage(event: event))),
                    icon: const Icon(Icons.insights_outlined),
                    label: const Text('My progress, consistency and badges'),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  SegmentedButton<BoardPeriod>(
                    showSelectedIcon: false,
                    segments: [
                      for (final p in BoardPeriod.values)
                        ButtonSegment(value: p, label: Text(p.label)),
                    ],
                    selected: {_period},
                    onSelectionChanged: (s) => setState(() => _period = s.first),
                  ),
                  if (board.value?.showGenderBoards ?? true) ...[
                    const SizedBox(height: AppSpacing.md),
                    SegmentedButton<BoardCohort>(
                      showSelectedIcon: false,
                      segments: [
                        for (final c in BoardCohort.values)
                          ButtonSegment(value: c, label: Text(c.label)),
                      ],
                      selected: {_cohort},
                      onSelectionChanged: (s) => setState(() => _cohort = s.first),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(spacing: AppSpacing.sm, children: [
                    for (final m in BoardMetric.values)
                      ChoiceChip(
                        label: Text(m.label),
                        selected: _metric == m,
                        onSelected: (_) => setState(() => _metric = m),
                      ),
                  ]),
                  const SizedBox(height: AppSpacing.lg),
                  board.when(
                    skipLoadingOnRefresh: true,
                    skipLoadingOnReload: true,
                    loading: () => const _BoardSkeleton(),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xl),
                      child: ErrorState(
                        title: 'Couldn\'t load the board',
                        message: e is CustomError
                            ? e.message
                            : 'Check your connection and try again.',
                        onRetry: () => ref.invalidate(eventBoardProvider(key)),
                      ),
                    ),
                    data: (b) => _Board(board: b, event: event, now: _now, period: _period, metric: _metric),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _statusLine(MemberEvent e, DateTime now) {
  final range = '${_day.format(e.startsOn)} – ${_day.format(e.endsOn)}';
  return switch (e.phase(now)) {
    EventPhase.upcoming => () {
        final d = e.daysUntilStart(now);
        return '$range · starts ${d == 1 ? 'tomorrow' : 'in $d days'}';
      }(),
    EventPhase.active => () {
        final left = e.daysLeft(now);
        final tail = left == 0 ? 'last day' : '$left ${left == 1 ? 'day' : 'days'} left';
        return 'Day ${e.dayNumber(now)} of ${e.totalDays} · $tail';
      }(),
    EventPhase.ended => '$range · ended',
  };
}

class _EventHeader extends StatelessWidget {
  const _EventHeader({required this.event, required this.now, this.onSwitch});

  final MemberEvent event;
  final DateTime now;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final phase = event.phase(now);

    final title = Row(
      children: [
        Expanded(
          child: Text(event.name,
              style: text.headlineSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        if (onSwitch != null)
          Icon(Icons.unfold_more, color: scheme.onSurfaceVariant),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onSwitch != null)
          Semantics(
            button: true,
            label: 'Switch event. Current: ${event.name}',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppSpacing.radiusField),
              onTap: onSwitch,
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6), child: title),
            ),
          )
        else
          title,
        const SizedBox(height: 4),
        Text(_statusLine(event, now),
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: GrowIn(
            builder: (c, t) => LinearProgressIndicator(
              value: event.progress(now) * t,
              minHeight: 6,
              color: phase == EventPhase.ended ? scheme.outline : scheme.primary,
              semanticsLabel: 'Event progress',
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_day.format(event.startsOn),
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            Text(_day.format(event.endsOn),
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ],
    );
  }
}

/// Three figures in one row, divided by rules rather than boxed in cards.
class _StatStrip extends StatelessWidget {
  const _StatStrip({required this.board, required this.loading});
  final EventBoard? board;

  /// Skeletons only while actually loading; a failed load shows dashes.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final b = board;

    int? bestRank;
    for (final r in b?.mine ?? const <BoardRow>[]) {
      if (bestRank == null || r.rank < bestRank) bestRank = r.rank;
    }

    Widget stat(String value, String label, {bool loading = false}) => Expanded(
          child: Column(
            children: [
              loading
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: SkeletonBox(width: 56, height: 20))
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: AnimatedSwitcher(
                        duration: chartDuration(context),
                        child: Text(value,
                            key: ValueKey(value),
                            style: text.titleLarge
                                ?.copyWith(fontFeatures: AppTheme.tabularFigures)),
                      ),
                    ),
              const SizedBox(height: 2),
              Text(label,
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        );

    return Semantics(
      container: true,
      child: IntrinsicHeight(
        child: Row(
          children: [
            stat(b == null ? '–' : _num.format(b.walkers), 'walkers',
                loading: b == null && loading),
            const VerticalDivider(width: AppSpacing.xl),
            stat(b == null ? '–' : _compact.format(b.totalSteps), 'steps together',
                loading: b == null && loading),
            const VerticalDivider(width: AppSpacing.xl),
            stat(bestRank == null ? '–' : '#$bestRank', 'your rank',
                loading: b == null && loading),
          ],
        ),
      ),
    );
  }
}

class _Board extends StatelessWidget {
  const _Board({
    required this.board,
    required this.event,
    required this.now,
    required this.period,
    this.metric = BoardMetric.steps,
  });

  final EventBoard board;
  final MemberEvent event;
  final DateTime now;
  final BoardPeriod period;
  final BoardMetric metric;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    if (event.phase(now) == EventPhase.upcoming) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xl),
        child: EmptyState(
          icon: Icons.hourglass_empty,
          title: 'The board opens on ${_day.format(event.startsOn)}',
          message:
              '${board.walkers} ${board.walkers == 1 ? 'walker is' : 'walkers are'} '
              'signed up. Steps count from the first day of the event.',
        ),
      );
    }
    if (board.nobodyHasWalked) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xl),
        child: EmptyState(
          icon: Icons.directions_walk,
          animation: BrandAnimationKind.walker,
          title: period == BoardPeriod.day ? 'No steps yet today' : 'No steps yet',
          message: 'Go for a walk and you\'ll be first on the board.',
        ),
      );
    }

    final podium = board.rows.length >= 3 && board.rows[2].rankedValue > 0;
    final listRows = podium ? board.rows.skip(3).toList() : board.rows;
    final outside = board.mineOutsideTop;

    Widget rowsCard(List<BoardRow> rows) => Card(
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(indent: 64),
                LeaderboardTile(
                  rank: rows[i].rank,
                  name: rows[i].name,
                  steps: rows[i].steps,
                  isCurrentUser: rows[i].mine,
                  valueText: metric == BoardMetric.steps
                      ? null
                      : formatMetric(metric, rows[i].rankedValue, _num.format),
                ),
              ],
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (podium) ...[
          _Podium(top: board.rows.take(3).toList(), metric: metric),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (listRows.isNotEmpty) rowsCard(listRows),
        if (outside.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          Text('Your household', style: text.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          rowsCard(outside),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Each profile is ranked on its own steps. '
          'Updated as people sync.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Top three on stepped plinths: 2nd, 1st, 3rd.
class _Podium extends StatelessWidget {
  const _Podium({required this.top, required this.metric});
  final List<BoardRow> top;
  final BoardMetric metric;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    Widget place(BoardRow r, double height, Color color) =>
        Expanded(child: _PodiumPlace(row: r, height: height, color: color, metric: metric));

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        place(top[1], 64, brand.silver),
        const SizedBox(width: AppSpacing.sm),
        place(top[0], 92, brand.gold),
        const SizedBox(width: AppSpacing.sm),
        place(top[2], 44, brand.bronze),
      ],
    );
  }
}

class _PodiumPlace extends StatelessWidget {
  const _PodiumPlace(
      {required this.row, required this.height, required this.color, required this.metric});
  final BoardMetric metric;
  final BoardRow row;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final brand = context.brand;

    return Semantics(
      label: 'Rank ${row.rank}, ${row.name}${row.mine ? ', you' : ''}, '
          '${_num.format(row.steps)} steps',
      excludeSemantics: true,
      child: Column(
        children: [
          Text(
            row.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.titleSmall?.copyWith(
                color: row.mine ? scheme.primary : scheme.onSurface),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              metric == BoardMetric.steps
                  ? _num.format(row.steps)
                  : formatMetric(metric, row.rankedValue, _num.format),
              style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: AppTheme.tabularFigures),
            ),
          ),
          const SizedBox(height: 6),
          GrowIn(builder: (c, t) => Container(
            height: math.max(28, height * t),
            width: double.infinity,
            alignment: Alignment.topCenter,
            padding: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Text(
              '${row.rank}',
              style: text.titleLarge?.copyWith(
                  color: brand.onMedal, fontFeatures: AppTheme.tabularFigures),
            ),
          )),
        ],
      ),
    );
  }
}

class _BoardSkeleton extends StatelessWidget {
  const _BoardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading the board',
      child: Column(
        children: [
          for (var i = 0; i < 6; i++)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Row(children: [
                SkeletonBox(width: 36, height: 36, radius: 18),
                SizedBox(width: AppSpacing.md),
                Expanded(child: SkeletonBox(height: 16)),
                SizedBox(width: AppSpacing.xl),
                SkeletonBox(width: 64, height: 16),
              ]),
            ),
        ],
      ),
    );
  }
}

class _DashboardSkeleton extends StatelessWidget {
  const _DashboardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: AppSpacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 220, height: 26),
          SizedBox(height: 10),
          SkeletonBox(width: 180, height: 14),
          SizedBox(height: AppSpacing.lg),
          SkeletonBox(height: 6),
          SizedBox(height: AppSpacing.xxl),
          _BoardSkeleton(),
        ],
      ),
    );
  }
}

/// Paused / cancelled notices, a missing-sex prompt, and announcements.
class _StatusNotices extends ConsumerWidget {
  const _StatusNotices({required this.event, required this.board});
  final MemberEvent event;
  final EventBoard? board;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(activeProfileProvider).value;
    final stats = ref.watch(myEventStatsProvider(event.id)).value;
    final notes = <Widget>[];

    Widget note(IconData icon, String title, String body, {VoidCallback? onTap}) => Card(
          child: ListTile(
            leading: Icon(icon, color: scheme.primary),
            title: Text(title),
            subtitle: Text(body),
            onTap: onTap,
            trailing: onTap == null ? null : const Icon(Icons.chevron_right),
          ),
        );

    if (board?.status == 'paused') {
      notes.add(note(Icons.pause_circle_outline, 'Event paused',
          'The organizers paused this event. Your steps are still being saved.'));
    } else if (board?.status == 'cancelled') {
      notes.add(note(Icons.cancel_outlined, 'Event cancelled',
          'This event was cancelled by the organizers.'));
    }
    if (profile != null && profile.sex == null && (board?.showGenderBoards ?? true)) {
      notes.add(note(Icons.wc_outlined, 'Add your sex to your profile',
          'Needed to appear on the men\'s or women\'s board. You stay on the overall board either way.',
          onTap: () => context.pushNamed(RouteNames.profileEdit,
              pathParameters: {'profileId': profile.id})));
    }
    for (final a in stats?.announcements.take(3) ?? const <({String title, String body, DateTime at})>[]) {
      notes.add(note(Icons.campaign_outlined, a.title, a.body));
    }
    if (notes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final n in notes) Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: n),
        ],
      ),
    );
  }
}

/// Percentile, gap to the next rank, and comparison with the average.
class _Standing extends StatelessWidget {
  const _Standing({required this.board, required this.metric});
  final EventBoard? board;
  final BoardMetric metric;

  @override
  Widget build(BuildContext context) {
    final b = board;
    if (b == null || b.mine.isEmpty || b.nobodyHasWalked) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final me = b.mine.reduce((a, c) => a.rank <= c.rank ? a : c);
    final vsAvg = me.rankedValue - b.averageValue;
    String f(int v) => formatMetric(metric, v, _num.format);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('#${me.rank}${me.topPct == null ? '' : ' · top ${me.topPct}%'}',
                style: text.titleLarge?.copyWith(fontFeatures: AppTheme.tabularFigures)),
            const SizedBox(height: 4),
            Text(
              me.rank == 1
                  ? 'You\'re leading.'
                  : '${f(me.gap)} behind the next place.',
              style: text.bodyMedium,
            ),
            Text(
              vsAvg >= 0
                  ? '${f(vsAvg)} above the event average.'
                  : '${f(-vsAvg)} below the event average.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
