import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../features/activity/history_math.dart';
import '../../../features/activity/step_providers.dart';
import '../../../features/events/event_models.dart';
import '../../../features/events/event_providers.dart';
import '../../../models/custom_error.dart';
import '../../../models/walker_profile.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/animated_count.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/brand_animation.dart';
import '../../widgets/infographics.dart';
import '../../widgets/state_widgets.dart';

final _num = NumberFormat.decimalPattern();

/// Home answers three questions at a glance: how am I doing today, where do
/// I stand in the event, and is my streak alive.
class HomePage extends ConsumerWidget {
  const HomePage({super.key, this.now});

  /// Injectable clock for tests.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileState = ref.watch(activeProfileProvider);

    return AppShell(
      current: AppTab.home,
      title: 'Home',
      onRefresh: () {
        ref.invalidate(profilesProvider);
        ref.read(stepTrackingProvider.notifier).refresh();
        ref.invalidate(eventBoardProvider);
      },
      body: profileState.when(
        skipLoadingOnRefresh: false,
        loading: () => const PageContainer(child: _HomeSkeleton()),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load your profile.',
          onRetry: () => ref.invalidate(profilesProvider),
        ),
        data: (profile) => profile == null
            ? ErrorState(
                title: 'No profile found',
                message: 'Your account has no walker profile yet.',
                onRetry: () => ref.invalidate(profilesProvider))
            : _HomeContent(profile: profile, now: (now ?? DateTime.now)()),
      ),
    );
  }
}

String _greeting(DateTime now) {
  final h = now.hour;
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

class _HomeContent extends ConsumerWidget {
  const _HomeContent({required this.profile, required this.now});

  final WalkerProfile profile;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final tracking = ref.watch(stepTrackingProvider).value;
    final history = ref.watch(activityHistoryProvider).value;
    final name = profile.displayName.trim();

    final steps = tracking?.displaySteps ?? 0;
    final goal = profile.dailyGoal;
    final reached = steps >= goal && steps > 0;
    final streak = history == null
        ? null
        : computeStreak(
            history.withLive(now, DayRecord(steps: steps)), now);

    return PageContainer(
      child: ListView(
        padding: AppSpacing.pagePadding,
        children: [
          Text(
            name.isEmpty ? _greeting(now) : '${_greeting(now)}, $name',
            style: text.headlineSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(DateFormat.MMMMEEEEd().format(now),
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.xl),

          // ---- Today ----
          Card(
            child: InkWell(
              onTap: () => context.go('/walkHome/${profile.accountId}'),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Semantics(
                  button: true,
                  label: '${_num.format(steps)} of ${_num.format(goal)} steps '
                      'today. Opens Walk.',
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Wraps at large text sizes instead of overflowing.
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.end,
                        spacing: AppSpacing.sm,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: AnimatedCount(
                              value: steps,
                              style: text.displayMedium?.copyWith(
                                  fontFeatures: AppTheme.tabularFigures),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('steps today',
                                style: text.bodyLarge
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: goal <= 0 ? 0 : (steps / goal).clamp(0.0, 1.0)),
                          duration: chartDuration(context),
                          curve: Curves.easeOutCubic,
                          builder: (c, v, _) => LinearProgressIndicator(
                            value: v,
                            minHeight: 10,
                            color: reached ? context.brand.success : scheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              reached
                                  ? 'Goal of ${_num.format(goal)} reached'
                                  : '${_num.format((goal - steps).clamp(0, goal))} to go '
                                      'of ${_num.format(goal)}',
                              style: text.bodyMedium,
                            ),
                          ),
                          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ---- Event ----
          Text('Your event', style: text.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          _EventSummary(profile: profile, now: now),

          // ---- Streak (plain row, not another card) ----
          if (streak != null) ...[
            const SizedBox(height: AppSpacing.xl),
            InkWell(
              borderRadius: BorderRadius.circular(AppSpacing.radiusField),
              onTap: () => context.go('/activity'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Row(
                  children: [
                    if (streak.current > 0)
                      const BrandAnimation(BrandAnimationKind.streakFlame,
                          size: 32, semanticLabel: 'Streak')
                    else
                      Icon(Icons.local_fire_department, color: context.brand.gold),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        streak.current == 0
                            ? 'No streak yet. Reach your goal today to start one.'
                            : 'Streak: ${streak.current} '
                                '${streak.current == 1 ? 'day' : 'days'} '
                                '(best ${streak.best})',
                        style: text.bodyLarge,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EventSummary extends ConsumerWidget {
  const _EventSummary({required this.profile, required this.now});
  final WalkerProfile profile;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final event = ref.watch(currentEventProvider);

    Widget shell(Widget child, {VoidCallback? onTap}) => Card(
          child: InkWell(
            onTap: onTap,
            child: Padding(padding: const EdgeInsets.all(AppSpacing.lg), child: child),
          ),
        );

    return event.when(
      loading: () => shell(const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 180, height: 18),
          SizedBox(height: 10),
          SkeletonBox(width: 220, height: 14),
        ],
      )),
      error: (e, _) => shell(
        Row(children: [
          Icon(Icons.cloud_off_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          const Expanded(child: Text('Couldn\'t load your event. Tap to retry.')),
        ]),
        onTap: () => ref.invalidate(myEventsProvider),
      ),
      data: (e) {
        if (e == null) {
          return shell(Text(
            'You\'re not on an event yet. Your administrator adds members '
            'to each walkathon; your steps are counted in the meantime.',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ));
        }
        final board = ref
            .watch(eventBoardProvider(boardKey(e.id, BoardPeriod.event)))
            .value;
        BoardRow? mine;
        for (final r in board?.mine ?? const <BoardRow>[]) {
          if (r.profileId == profile.id) mine = r;
        }
        final phase = e.phase(now);
        final String line2 = switch (phase) {
          EventPhase.upcoming => () {
              final d = e.daysUntilStart(now);
              return 'Starts ${d == 1 ? 'tomorrow' : 'in $d days'}';
            }(),
          EventPhase.ended => 'Ended',
          EventPhase.active => () {
              final left = e.daysLeft(now);
              return 'Day ${e.dayNumber(now)} of ${e.totalDays}'
                  '${left == 0 ? ' · last day' : ' · $left ${left == 1 ? 'day' : 'days'} left'}';
            }(),
        };

        return shell(
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.name,
                        style: text.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(line2,
                        style: text.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                    if (mine != null && phase != EventPhase.upcoming) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        '#${mine.rank} of ${board!.walkers} · '
                        '${_num.format(mine.steps)} steps',
                        style: text.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: AppTheme.tabularFigures),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
          onTap: () => context.go('/leaderBoard'),
        );
      },
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: AppSpacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 220, height: 26),
          SizedBox(height: 10),
          SkeletonBox(width: 140, height: 14),
          SizedBox(height: AppSpacing.xl),
          SkeletonBox(height: 150, radius: AppSpacing.radiusCard),
          SizedBox(height: AppSpacing.xl),
          SkeletonBox(height: 84, radius: AppSpacing.radiusCard),
        ],
      ),
    );
  }
}
