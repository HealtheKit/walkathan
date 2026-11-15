import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/social/social_models.dart';
import '../../../features/social/social_providers.dart';
import '../../../models/custom_error.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/app_snackbar.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/buttons.dart';
import '../../widgets/state_widgets.dart';
import '../leader_board/leaderboard_widgets.dart';
import 'group_detail_page.dart';

enum _SocialTab { friends, groups }

/// Friends and groups for the active profile.
class SocialPage extends ConsumerStatefulWidget {
  const SocialPage({super.key});

  @override
  ConsumerState<SocialPage> createState() => _SocialPageState();
}

class _SocialPageState extends ConsumerState<SocialPage> {
  _SocialTab _tab = _SocialTab.friends;

  void _refresh() {
    ref.invalidate(friendsOverviewProvider);
    ref.invalidate(friendBoardProvider);
    ref.invalidate(myGroupsProvider);
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      current: AppTab.social,
      title: 'Social',
      onRefresh: _refresh,
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: PageContainer(
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: AppSpacing.pagePadding,
            children: [
              SegmentedButton<_SocialTab>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _SocialTab.friends, label: Text('Friends')),
                  ButtonSegment(value: _SocialTab.groups, label: Text('Groups')),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              const SizedBox(height: AppSpacing.xl),
              if (_tab == _SocialTab.friends) const _FriendsView() else const _GroupsView(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs a social action and reports failure in a dialog.
Future<bool> _guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } on CustomError catch (e) {
    if (context.mounted) errorDialog(context, e);
    return false;
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xl, bottom: AppSpacing.sm),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

// ================================================================ friends

class _FriendsView extends ConsumerStatefulWidget {
  const _FriendsView();

  @override
  ConsumerState<_FriendsView> createState() => _FriendsViewState();
}

class _FriendsViewState extends ConsumerState<_FriendsView> {
  SocialPeriod _period = SocialPeriod.day;
  final _code = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _reload() {
    ref.invalidate(friendsOverviewProvider);
    ref.invalidate(friendBoardProvider);
  }

  Future<void> _send(String me) async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() => _sending = true);
    String? status;
    await _guard(context, () async {
      status = await ref.read(socialRepositoryProvider).requestByCode(me, code);
    });
    if (!mounted) return;
    setState(() => _sending = false);
    if (status == null) return;
    final message = switch (status) {
      'sent' => 'Request sent. They\'ll appear here once they accept.',
      'accepted' => 'You\'re now friends.',
      'pending' => 'You already sent this person a request.',
      'already_friends' => 'You\'re already friends.',
      'limit' => 'You have too many requests waiting. Cancel one first.',
      _ => 'No one found with that code. Check it and try again.',
    };
    showAppSnackBar(context, message, isError: status == 'not_found' || status == 'limit');
    if (status == 'sent' || status == 'accepted') {
      _code.clear();
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = ref.watch(friendsOverviewProvider);
    final me = ref.watch(activeProfileProvider).value?.id;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final repo = ref.read(socialRepositoryProvider);

    return overview.when(
      loading: () => const _ListSkeleton(),
      error: (e, _) => ErrorState(
        message: e is CustomError ? e.message : 'Could not load your friends.',
        onRetry: _reload,
      ),
      data: (o) {
        if (o == null || me == null) {
          return const EmptyState(title: 'No profile', message: 'Add a profile first.');
        }
        final board = ref.watch(friendBoardProvider(_period));
        final visible = o.friends.where((f) => !f.hidden).toList();
        final hidden = o.friends.where((f) => f.hidden).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- leaderboard ----
            if (o.friends.isEmpty)
              Text(
                'Add a friend to compare steps. Friends see your name and '
                'step totals only after you both agree, and you can stop '
                'sharing at any time.',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              )
            else ...[
              SegmentedButton<SocialPeriod>(
                showSelectedIcon: false,
                segments: [
                  for (final p in const [SocialPeriod.day, SocialPeriod.week, SocialPeriod.month])
                    ButtonSegment(value: p, label: Text(p.label)),
                ],
                selected: {_period},
                onSelectionChanged: (s) => setState(() => _period = s.first),
              ),
              const SizedBox(height: AppSpacing.md),
              board.when(
                skipLoadingOnReload: true,
                skipLoadingOnRefresh: true,
                loading: () => const _ListSkeleton(rows: 3),
                error: (e, _) => ErrorState(
                    message: 'Could not load the board.',
                    onRetry: () => ref.invalidate(friendBoardProvider)),
                data: (rows) => Card(
                  child: Column(children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0) const Divider(indent: 64),
                      LeaderboardTile(
                          rank: rows[i].rank,
                          name: rows[i].name,
                          steps: rows[i].steps ?? 0,
                          isCurrentUser: rows[i].mine),
                    ],
                  ]),
                ),
              ),
              if (!o.sharing)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    'Your steps are hidden from friends. Turn sharing on in '
                    'your profile to appear on their boards.',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],

            // ---- add ----
            const _Heading('Add a friend'),
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(text: 'Your code  ', children: [
                      TextSpan(
                          text: o.code,
                          style: text.titleMedium?.copyWith(letterSpacing: 2)),
                    ]),
                    style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy your code',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: o.code));
                    if (context.mounted) showAppSnackBar(context, 'Code copied');
                  },
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Friend\'s code',
                prefixIcon: Icon(Icons.person_add_alt),
              ),
              onSubmitted: (_) => _send(me),
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
                label: 'Send request', loading: _sending, onPressed: () => _send(me)),

            // ---- requests ----
            if (o.incoming.isNotEmpty) ...[
              const _Heading('Requests'),
              Card(
                child: Column(children: [
                  for (final r in o.incoming)
                    ListTile(
                      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: const Text('wants to be friends'),
                      trailing: Wrap(spacing: 4, children: [
                        IconButton(
                          tooltip: 'Decline',
                          icon: const Icon(Icons.close),
                          onPressed: () async {
                            if (await _guard(context, () => repo.respond(me, r.profileId, false))) {
                              _reload();
                            }
                          },
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Accept',
                          icon: const Icon(Icons.check),
                          onPressed: () async {
                            if (await _guard(context, () => repo.respond(me, r.profileId, true))) {
                              _reload();
                            }
                          },
                        ),
                      ]),
                    ),
                ]),
              ),
            ],
            if (o.outgoing.isNotEmpty) ...[
              const _Heading('Waiting for them'),
              Card(
                child: Column(children: [
                  for (final r in o.outgoing)
                    ListTile(
                      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: TextButton(
                        onPressed: () async {
                          if (await _guard(context, () => repo.removeFriend(me, r.profileId))) {
                            _reload();
                          }
                        },
                        child: const Text('Cancel'),
                      ),
                    ),
                ]),
              ),
            ],

            // ---- friends ----
            if (o.friends.isNotEmpty) ...[
              const _Heading('Friends'),
              Card(
                child: Column(children: [
                  for (final f in [...visible, ...hidden])
                    ListTile(
                      leading: CircleAvatar(
                          child: Text(f.name.isEmpty ? '?' : f.name.characters.first.toUpperCase())),
                      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(f.hidden
                          ? 'Hidden from your lists'
                          : f.sharing
                              ? '${f.todaySteps ?? 0} steps today'
                              : 'Not sharing steps'),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Friend options',
                        onSelected: (a) async {
                          final ok = await _guard(context, () async {
                            switch (a) {
                              case 'hide':
                                await repo.setHidden(me, f.profileId, !f.hidden);
                              case 'remove':
                                await repo.removeFriend(me, f.profileId);
                              case 'block':
                                await repo.setBlocked(me, f.profileId, true);
                            }
                          });
                          if (ok) _reload();
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'hide', child: Text(f.hidden ? 'Show again' : 'Hide')),
                          const PopupMenuItem(value: 'remove', child: Text('Remove friend')),
                          const PopupMenuItem(value: 'block', child: Text('Block')),
                        ],
                      ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'Hide keeps the friendship but removes them from your '
                  'lists. Block ends it and stops them finding you; they '
                  'are not told.',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
            if (o.blocked.isNotEmpty) ...[
              const _Heading('Blocked'),
              Card(
                child: Column(children: [
                  for (final b in o.blocked)
                    ListTile(
                      title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: TextButton(
                        onPressed: () async {
                          if (await _guard(context, () => repo.setBlocked(me, b.profileId, false))) {
                            _reload();
                          }
                        },
                        child: const Text('Unblock'),
                      ),
                    ),
                ]),
              ),
            ],
          ],
        );
      },
    );
  }
}

// ================================================================= groups

class _GroupsView extends ConsumerWidget {
  const _GroupsView();

  Future<String?> _ask(BuildContext context,
      {required String title, required String label, required String action, String? help}) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (help != null) ...[Text(help), const SizedBox(height: AppSpacing.md)],
          TextField(
              controller: c,
              autofocus: true,
              maxLength: 60,
              decoration: InputDecoration(labelText: label)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(d, c.text.trim()), child: Text(action)),
        ],
      ),
    );
  }

  void _open(BuildContext context, WidgetRef ref, String groupId) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => GroupDetailPage(groupId: groupId)));
    ref.invalidate(myGroupsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(myGroupsProvider);
    final me = ref.watch(activeProfileProvider).value?.id;
    final repo = ref.read(socialRepositoryProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Future<void> create() async {
      final name = await _ask(context,
          title: 'New group', label: 'Group name', action: 'Create');
      if (name == null || name.length < 2 || me == null || !context.mounted) return;
      String? id;
      if (await _guard(context, () async => id = await repo.createGroup(me, name))) {
        ref.invalidate(myGroupsProvider);
        if (id != null && context.mounted) _open(context, ref, id!);
      }
    }

    Future<void> join() async {
      final code = await _ask(context,
          title: 'Join a group',
          label: 'Invite code',
          action: 'Join',
          help: 'Joining shares your name and step totals with the group\'s members.');
      if (code == null || code.isEmpty || me == null || !context.mounted) return;
      ({String status, String? groupId})? r;
      if (!await _guard(context, () async => r = await repo.joinGroup(me, code))) return;
      if (!context.mounted || r == null) return;
      switch (r!.status) {
        case 'joined' || 'already_member':
          ref.invalidate(myGroupsProvider);
          if (r!.groupId != null) _open(context, ref, r!.groupId!);
        case 'full':
          showAppSnackBar(context, 'This group is full.', isError: true);
        case 'rate_limited':
          showAppSnackBar(context, 'Too many tries. Wait 15 minutes and try again.',
              isError: true);
        default:
          showAppSnackBar(context, 'That code isn\'t valid. It may have expired.',
              isError: true);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
              child: AppButton(label: 'Create group', icon: Icons.add, onPressed: create)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
              child: AppButton(
                  label: 'Join with code',
                  icon: Icons.vpn_key_outlined,
                  variant: AppButtonVariant.outlined,
                  onPressed: join)),
        ]),
        const SizedBox(height: AppSpacing.xl),
        groups.when(
          loading: () => const _ListSkeleton(rows: 3),
          error: (e, _) => ErrorState(
              message: e is CustomError ? e.message : 'Could not load your groups.',
              onRetry: () => ref.invalidate(myGroupsProvider)),
          data: (list) {
            if (list.isEmpty) {
              return Text(
                'Groups are private step challenges for a team, family or '
                'class. Create one and share its invite code, or join one '
                'with a code you were given. One group per team makes it '
                'easy to compare teams from the admin report.',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              );
            }
            return Card(
              child: Column(children: [
                for (var i = 0; i < list.length; i++) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    title: Text(list[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      '${list[i].memberCount} member${list[i].memberCount == 1 ? '' : 's'}',
                      if (list[i].role.isAdmin) list[i].role.label,
                      if (list[i].mysteryMode) 'Mystery Mode',
                      if (list[i].hasChallenge) 'Challenge',
                    ].join(' · ')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, ref, list[i].id),
                  ),
                ],
              ]),
            );
          },
        ),
      ],
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton({this.rows = 4});
  final int rows;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: Column(children: [
        for (var i = 0; i < rows; i++)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Row(children: [
              SkeletonBox(width: 36, height: 36, radius: 18),
              SizedBox(width: AppSpacing.md),
              Expanded(child: SkeletonBox(height: 16)),
            ]),
          ),
      ]),
    );
  }
}
