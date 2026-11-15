import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../features/social/social_models.dart';
import '../../../features/social/social_providers.dart';
import '../../../models/custom_error.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/state_widgets.dart';
import '../leader_board/leaderboard_widgets.dart';
import 'group_settings_page.dart';

final _day = DateFormat.MMMd();

/// A group's leaderboard. Boards update on their own; nothing is "started".
class GroupDetailPage extends ConsumerStatefulWidget {
  const GroupDetailPage({super.key, required this.groupId});
  final String groupId;

  @override
  ConsumerState<GroupDetailPage> createState() => _GroupDetailPageState();
}

class _GroupDetailPageState extends ConsumerState<GroupDetailPage> {
  SocialPeriod _period = SocialPeriod.day;
  Timer? _timer;

  GroupBoardKey get _key => (groupId: widget.groupId, period: _period);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) ref.invalidate(groupBoardProvider(_key));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _settings(GroupInfo g) async {
    final gone = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => GroupSettingsPage(group: g)));
    if (!mounted) return;
    if (gone == true) {
      Navigator.of(context).pop();
    } else {
      // A cleared challenge must not leave us on the Challenge tab.
      setState(() => _period = SocialPeriod.day);
      ref.invalidate(groupBoardProvider);
    }
  }

  Future<void> _leave(GroupInfo g) async {
    final me = ref.read(activeProfileProvider).value?.id;
    if (me == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Leave group?'),
        content: Text('You\'ll stop appearing on "${g.name}" and can rejoin '
            'only with a new invite code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(socialRepositoryProvider).leaveGroup(me, g.id);
      if (mounted) Navigator.of(context).pop();
    } on CustomError catch (e) {
      if (mounted) errorDialog(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(groupBoardProvider(_key));
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final g = board.value?.group;

    return Scaffold(
      appBar: AppBar(
        // Long-press the name: the admin shortcut into Group Settings.
        title: GestureDetector(
          onLongPress: g != null && g.role.isAdmin ? () => _settings(g) : null,
          child: Text(g?.name ?? 'Group', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          if (g != null && g.role.isAdmin)
            IconButton(
                tooltip: 'Group settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => _settings(g))
          else if (g != null)
            PopupMenuButton<String>(
              onSelected: (_) => _leave(g),
              itemBuilder: (_) =>
                  const [PopupMenuItem(value: 'leave', child: Text('Leave group'))],
            ),
        ],
      ),
      body: board.when(
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load this group.',
          onRetry: () => ref.invalidate(groupBoardProvider(_key)),
        ),
        data: (b) {
          final periods = [
            SocialPeriod.day,
            SocialPeriod.week,
            SocialPeriod.month,
            if (b.group.hasChallenge) SocialPeriod.challenge,
          ];
          final outside = b.mineOutsideTop;

          Widget rows(List<RankRow> list) => Card(
                child: Column(children: [
                  for (var i = 0; i < list.length; i++) ...[
                    if (i > 0) const Divider(indent: 64),
                    LeaderboardTile(
                      rank: list[i].rank,
                      name: list[i].name,
                      steps: list[i].steps,
                      isCurrentUser: list[i].mine,
                    ),
                  ],
                ]),
              );

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(groupBoardProvider(_key)),
            child: PageContainer(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: AppSpacing.pagePadding,
                children: [
                  Text(
                    [
                      '${b.group.memberCount} member${b.group.memberCount == 1 ? '' : 's'}',
                      if (b.group.hasChallenge)
                        'Challenge ${_day.format(b.group.challengeStart!)} – '
                            '${_day.format(b.group.challengeEnd!)}',
                    ].join(' · '),
                    style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  SegmentedButton<SocialPeriod>(
                    showSelectedIcon: false,
                    segments: [
                      for (final p in periods)
                        ButtonSegment(
                            value: p,
                            // never wrap a label onto two lines on narrow phones
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                  p == SocialPeriod.week
                                      ? 'Week'
                                      : p == SocialPeriod.month
                                          ? 'Month'
                                          : p.label,
                                  maxLines: 1),
                            )),
                    ],
                    selected: {periods.contains(_period) ? _period : SocialPeriod.day},
                    onSelectionChanged: (s) => setState(() => _period = s.first),
                  ),
                  if (b.stepsHidden || b.excludesToday) ...[
                    const SizedBox(height: AppSpacing.md),
                    Row(children: [
                      Icon(Icons.visibility_off_outlined,
                          size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          b.stepsHidden
                              ? 'Mystery Mode: today shows ranks only. Step '
                                  'counts are revealed tomorrow.'
                              : 'Mystery Mode: this total runs up to yesterday.',
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ]),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  if (b.rows.isEmpty)
                    const EmptyState(
                        icon: Icons.group_outlined, title: 'No members yet')
                  else
                    rows(b.rows),
                  if (outside.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xl),
                    Text('Your position', style: text.titleMedium),
                    const SizedBox(height: AppSpacing.sm),
                    rows(outside),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
