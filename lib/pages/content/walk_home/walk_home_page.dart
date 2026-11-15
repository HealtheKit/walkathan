import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../features/activity/movement_tracker.dart';
import '../../../features/activity/step_providers.dart';
import '../../../features/walk_workout/application/walk_session_controller.dart';
import '../../../features/walk_workout/presentation/walk_ui.dart';
import '../../../models/walker_profile.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../../models/custom_error.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/animated_count.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/brand_animation.dart';
import '../../widgets/buttons.dart';
import '../../widgets/state_widgets.dart';

/// Today's steps for the ACTIVE profile. Steps come only from the phone's
/// sensor or Apple Health / Health Connect; there is no manual entry.
class WalkHomePage extends ConsumerStatefulWidget {
  final String userId;

  const WalkHomePage({required this.userId, super.key});

  @override
  ConsumerState<WalkHomePage> createState() => _WalkHomePageState();
}

class _WalkHomePageState extends ConsumerState<WalkHomePage>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The live counter moves the number between syncs; this is the safety
    // net that also picks up Health app batches.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    if (mounted) ref.read(stepTrackingProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tracking = ref.watch(stepTrackingProvider);
    final profile = ref.watch(activeProfileProvider).value;

    return AppShell(
      current: AppTab.walk,
      title: 'Walk',
      onRefresh: _refresh,
      body: tracking.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: 'Could not start step tracking.',
          onRetry: () => ref.invalidate(stepTrackingProvider),
        ),
        data: (state) => RefreshIndicator(
          onRefresh: () => ref.read(stepTrackingProvider.notifier).refresh(),
          child: PageContainer(
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: AppSpacing.pagePadding,
              children: [
                if (profile != null)
                  _WalkingAs(profile: profile, live: state.live && !state.readOnly),
                const SizedBox(height: AppSpacing.md),
                if (state.readOnly)
                  _OtherPhoneBanner(state: state, profile: profile)
                else
                  _StatusBanner(state: state),
                _GoalCard(
                  steps: state.displaySteps,
                  goal: profile?.dailyGoal ?? WalkerProfile.defaultGoal,
                  loading: state.syncing && state.today == null,
                ),
                const SizedBox(height: AppSpacing.lg),
                _MetricsRow(state: state),
                const SizedBox(height: AppSpacing.lg),
                const _WalkWorkoutCard(),
                const SizedBox(height: AppSpacing.lg),
                _SyncFooter(state: state),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WalkingAs extends StatelessWidget {
  const _WalkingAs({required this.profile, required this.live});
  final WalkerProfile profile;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            'Walking as ${profile.displayName.isEmpty ? profile.relation.label : profile.displayName}',
            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (live)
          Semantics(
            label: 'Counting live',
            excludeSemantics: true,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: context.brand.success, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text('Live', style: text.labelMedium),
            ]),
          ),
      ],
    );
  }
}

/// Shown when this phone counts steps for a different profile. Each person's
/// steps come only from their own phone; nothing is shared or mirrored.
class _OtherPhoneBanner extends ConsumerWidget {
  const _OtherPhoneBanner({required this.state, required this.profile});
  final StepTrackingState state;
  final WalkerProfile? profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final who = profile?.displayName.isNotEmpty == true ? profile!.displayName : 'this profile';
    final owner = state.otherOwnerName?.isNotEmpty == true
        ? state.otherOwnerName!
        : 'another profile';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: _Banner(
        icon: Icons.phonelink_lock_outlined,
        title: 'This phone counts steps for $owner',
        message: 'Each person\'s steps come from their own phone, so they are '
            'never shared or copied. The number below is what $who has '
            'walked with their own phone.'
            '${state.canMoveDevice ? '' : ' A phone can switch to another profile after it has not been used for 7 days.'}',
        action: state.canMoveDevice ? 'Use this phone for $who instead' : null,
        onAction: state.canMoveDevice
            ? () async {
                try {
                  await ref
                      .read(stepTrackingProvider.notifier)
                      .useThisPhoneForActiveProfile();
                } on CustomError catch (e) {
                  if (context.mounted) errorDialog(context, e);
                }
              }
            : null,
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard(
      {required this.steps, required this.goal, required this.loading});

  final int steps;
  final int goal;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final progress = goal <= 0 ? 0.0 : (steps / goal).clamp(0.0, 1.0);
    final reached = steps >= goal && steps > 0;
    final fmt = NumberFormat.decimalPattern();

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: AppSpacing.xxl),
        child: Semantics(
          label: '${fmt.format(steps)} of ${fmt.format(goal)} steps today'
              '${reached ? ', goal reached' : ''}',
          excludeSemantics: true,
          child: Column(
            children: [
              SizedBox(
                width: 220,
                height: 220,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: loading ? null : progress,
                        strokeWidth: 14,
                        strokeCap: StrokeCap.round,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: reached ? context.brand.success : scheme.primary,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: AnimatedCount(
                            value: steps,
                            style: text.displayMedium?.copyWith(
                                fontFeatures: AppTheme.tabularFigures),
                          ),
                        ),
                        Text(
                          'of ${fmt.format(goal)} steps',
                          style: text.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (reached) ...[
                const BrandAnimation(BrandAnimationKind.goalReached,
                    size: 88, semanticLabel: 'Goal reached'),
                const SizedBox(height: AppSpacing.sm),
              ],
              Text(
                reached
                    ? 'Goal reached. Great walking!'
                    : '${fmt.format((goal - steps).clamp(0, goal))} steps to go',
                style: text.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.state});
  final StepTrackingState state;

  @override
  Widget build(BuildContext context) {
    final day = state.today;
    final km = day?.distanceM == null ? null : day!.distanceM! / 1000;
    final tiles = <Widget>[
      _Metric(
        icon: Icons.straighten,
        label: 'Distance',
        value: km == null ? '–' : '${km.toStringAsFixed(2)} km',
      ),
      _Metric(
        icon: Icons.local_fire_department_outlined,
        label: 'Calories',
        value: day?.kcal == null ? '–' : '${day!.kcal} kcal',
      ),
      // Floors only when the platform actually reports them.
      if (day?.floors != null)
        _Metric(
          icon: Icons.stairs_outlined,
          label: 'Floors',
          value: '${day!.floors}',
        ),
    ];
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.md),
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(height: AppSpacing.sm),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: text.titleMedium),
            ),
            Text(label,
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Entry to the timed walk workout (route, pace, laps, summary). While a
/// walk exists it returns to that walk instead of starting another.
class _WalkWorkoutCard extends ConsumerWidget {
  const _WalkWorkoutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(walkStatusProvider);
    final live = status.isLive;
    return Card(
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
        leading: const Icon(Icons.timer_outlined),
        title: Text(live ? 'Walk workout: ${status.label.toLowerCase()}' : 'Start a walk workout'),
        subtitle: Text(live
            ? 'Tap to return to your walk.'
            : 'Track time, distance, pace and route for one walk.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => ref.read(walkNavProvider).toWalk(context, status),
      ),
    );
  }
}

/// Asks for location so steps taken while standing still (for example the
/// phone being shaken) can be ignored. Shown only when it would help.
class _LocationBanner extends StatelessWidget {
  const _LocationBanner();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MovementStatus>(
      valueListenable: MovementTracker.instance.status,
      builder: (context, status, _) {
        final tracker = MovementTracker.instance;
        final (String message, String action, VoidCallback onAction) = switch (status) {
          MovementStatus.needsPermission => (
              'Allow location so only real walking counts. Steps while you '
                  'stand still, or shake the phone, are ignored. Your location '
                  'stays on this phone and is never uploaded.',
              'Allow location',
              () => tracker.requestAndStart()
            ),
          MovementStatus.deniedForever => (
              'Location is blocked, so steps while standing still can\'t be '
                  'told apart. Allow it in the phone\'s settings.',
              'Open settings',
              () => tracker.openSettings()
            ),
          MovementStatus.serviceOff => (
              'Location is switched off on this phone, so steps while '
                  'standing still can\'t be told apart.',
              'Open settings',
              () => tracker.openSettings()
            ),
          _ => ('', '', () {}),
        };
        if (message.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: _Banner(
            icon: Icons.location_on_outlined,
            title: 'Count only when you move',
            message: message,
            action: action,
            onAction: onAction,
          ),
        );
      },
    );
  }
}

/// Explains why steps may be missing and offers the fix.
class _StatusBanner extends ConsumerWidget {
  const _StatusBanner({required this.state});
  final StepTrackingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(stepTrackingProvider.notifier);

    Widget? banner;
    if (state.needsHealthConnect) {
      banner = _Banner(
        icon: Icons.health_and_safety_outlined,
        title: 'Health Connect is needed',
        message: 'Install or update Health Connect so Tresundios can read '
            'your steps from your phone and wearable.',
        action: 'Open Health Connect',
        onAction: notifier.installHealthConnect,
      );
    } else if (state.needsPermission) {
      banner = _Banner(
        icon: Icons.directions_walk,
        title: 'Allow step access',
        message: 'We read steps from your phone or Health app. You can\'t '
            'enter steps by hand. Your steps stay private unless you share '
            'them.',
        action: 'Allow',
        onAction: notifier.requestPermissions,
      );
    } else if (state.unsupported) {
      banner = _Banner(
        icon: Icons.sensors_off,
        title: 'Steps unavailable on this device',
        message: 'This device has no step sensor or health service we can '
            'use. You can still view the leaderboard.',
        tone: scheme.error,
      );
    }

    if (banner == null) return const _LocationBanner();
    return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.lg), child: banner);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.onAction,
    this.tone,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? action;
  final VoidCallback? onAction;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = tone ?? scheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(title, style: text.titleMedium)),
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text(message,
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              AppButton(label: action!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}

class _SyncFooter extends StatelessWidget {
  const _SyncFooter({required this.state});
  final StepTrackingState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final String line;
    final IconData icon;
    if (state.readOnly) {
      line = 'Synced from their own phone';
      icon = Icons.cloud_done_outlined;
    } else if (state.syncing && state.lastSync == null) {
      line = 'Syncing…';
      icon = Icons.sync;
    } else if (state.pending > 0 || state.error != null) {
      line = 'Saved on this phone. It will upload when you\'re online.';
      icon = Icons.cloud_off_outlined;
    } else if (state.lastSync != null) {
      line = 'Last synced ${DateFormat('HH:mm').format(state.lastSync!)}';
      icon = Icons.cloud_done_outlined;
    } else {
      line = 'Not synced yet';
      icon = Icons.cloud_queue;
    }

    final excluded = state.today?.excludedSteps ?? 0;
    final fmt = NumberFormat.decimalPattern();

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(line,
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (state.pausedNotMoving)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              'Steps are paused: your phone is not moving from this spot. '
              'They count again as soon as you walk on.',
              style: text.bodySmall?.copyWith(color: scheme.error),
              textAlign: TextAlign.center,
            ),
          ),
        if (excluded > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              '${fmt.format(excluded)} steps were ignored because they happened '
              'while cycling, on a treadmill or exercise machine, or while '
              'the phone stayed in one place.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        Text(
          'Only real walking and running on the move count. Standing still, '
          'cycling, treadmills and exercise machines don\'t, and steps can\'t '
          'be typed in.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
