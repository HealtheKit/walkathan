import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/router/route_names.dart';
import '../../features/walk_workout/application/walk_session_controller.dart';
import '../../features/walk_workout/presentation/walk_ui.dart';
import '../../features/walk_workout/presentation/widgets/walk_status_banner.dart';
import '../../constants/firebase_constants.dart';
import '../../models/custom_error.dart';
import '../../models/walker_profile.dart';
import '../../providers/profile_providers.dart';
import '../../repositories/auth_repository_provider.dart';
import '../../theme/app_spacing.dart';
import '../../utils/error_dialog.dart';

enum AppTab { home, walk, activity, leaderboard, social }

/// Common frame for the signed-in screens: app bar (refresh + account menu)
/// plus bottom navigation on phones or a navigation rail on wide screens.
///
/// Navigation uses the existing route paths, so router config is unchanged.
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.current,
    required this.title,
    required this.body,
    this.onRefresh,
  });

  final AppTab current;
  final String title;
  final Widget body;
  final VoidCallback? onRefresh;

  static const _destinations = <({AppTab tab, IconData icon, IconData selected, String label})>[
    (tab: AppTab.home, icon: Icons.home_outlined, selected: Icons.home, label: 'Home'),
    (tab: AppTab.walk, icon: Icons.directions_walk_outlined, selected: Icons.directions_walk, label: 'Walk'),
    (tab: AppTab.activity, icon: Icons.insights_outlined, selected: Icons.insights, label: 'Activity'),
    (tab: AppTab.leaderboard, icon: Icons.emoji_events_outlined, selected: Icons.emoji_events, label: 'Event'),
    (tab: AppTab.social, icon: Icons.groups_outlined, selected: Icons.groups, label: 'Social'),
  ];

  void _go(BuildContext context, WidgetRef ref, AppTab tab) {
    // While a walk exists, the Walk tab opens THAT walk, never a new one.
    if (tab == AppTab.walk && ref.read(walkIsLiveProvider)) {
      ref.read(walkNavProvider).toWalk(context, ref.read(walkStatusProvider));
      return;
    }
    if (tab == current) return;
    switch (tab) {
      case AppTab.home:
        context.go('/home');
      case AppTab.walk:
        final uid = supabaseClient.auth.currentUser!.id;
        context.go('/walkHome/$uid');
      case AppTab.activity:
        context.go('/activity');
      case AppTab.leaderboard:
        context.go('/leaderBoard');
      case AppTab.social:
        context.go('/social');
    }
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(authRepositoryProvider).signout();
    } on CustomError catch (e) {
      if (!context.mounted) return;
      errorDialog(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = context.isExpanded;
    final index = _destinations.indexWhere((d) => d.tab == current);

    final staff = ref.watch(staffRoleProvider).value;
    final isSuperAdmin = staff == 'super';
    final reviewer = ref.watch(isTransferReviewerProvider).value ?? false;
    final pending = ref.watch(pendingTransferCountProvider).value ?? 0;
    final appBar = AppBar(
      title: Text(title),
      actions: [
        const _ProfileChip(),
        if (onRefresh != null)
          IconButton(
            tooltip: 'Refresh',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        PopupMenuButton<_MenuAction>(
          tooltip: 'Account',
          icon: const Icon(Icons.account_circle_outlined),
          onSelected: (action) {
            switch (action) {
              case _MenuAction.profiles:
                context.pushNamed(RouteNames.profiles);
              case _MenuAction.settings:
                context.pushNamed(RouteNames.settings);
              case _MenuAction.members:
                context.pushNamed(RouteNames.adminMembers);
              case _MenuAction.events:
                context.pushNamed(RouteNames.adminEvents);
              case _MenuAction.approvals:
                context.pushNamed(RouteNames.transferApprovals);
              case _MenuAction.changePassword:
                context.goNamed(RouteNames.changePassword);
              case _MenuAction.signOut:
                _signOut(context, ref);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _MenuAction.profiles,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.groups_2_outlined),
                title: Text('Profiles'),
              ),
            ),
            if (isSuperAdmin)
              const PopupMenuItem(
                value: _MenuAction.members,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.admin_panel_settings_outlined),
                  title: Text('Members (admin)'),
                ),
              ),
            if (staff.isStaff || reviewer)
              const PopupMenuItem(
                value: _MenuAction.events,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.event_outlined),
                  title: Text('Admin dashboard'),
                ),
              ),
            if (reviewer)
              PopupMenuItem(
                value: _MenuAction.approvals,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Badge(
                    isLabelVisible: pending > 0,
                    label: Text('$pending'),
                    child: const Icon(Icons.how_to_reg_outlined),
                  ),
                  title: const Text('Approvals'),
                ),
              ),
            const PopupMenuItem(
              value: _MenuAction.settings,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.settings_outlined),
                title: Text('Settings & help'),
              ),
            ),
            const PopupMenuItem(
              value: _MenuAction.changePassword,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.lock_reset),
                title: Text('Change password'),
              ),
            ),
            const PopupMenuItem(
              value: _MenuAction.signOut,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.logout),
                title: Text('Sign out'),
              ),
            ),
          ],
        ),
        const SizedBox(width: AppSpacing.xs),
      ],
    );

    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: (i) => _go(context, ref, _destinations[i].tab),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(),
            Expanded(
                child: SafeArea(
                    child: Column(children: [
              const WalkStatusBanner(),
              Expanded(child: body),
            ]))),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      // The walk banner sits directly under the app bar on every main screen.
      body: SafeArea(
          top: false,
          bottom: false,
          child: Column(children: [
            const WalkStatusBanner(),
            Expanded(child: body),
          ])),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => _go(context, ref, _destinations[i].tab),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              // the Walk tab carries the live walk chip
              icon: d.tab == AppTab.walk ? WalkStatusChip(child: Icon(d.icon)) : Icon(d.icon),
              selectedIcon:
                  d.tab == AppTab.walk ? WalkStatusChip(child: Icon(d.selected)) : Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

enum _MenuAction {
  profiles,
  settings,
  members,
  events,
  approvals,
  changePassword,
  signOut
}

/// Shows who is walking on this device; tap to switch profile.
class _ProfileChip extends ConsumerWidget {
  const _ProfileChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeProfileProvider).value;
    final scheme = Theme.of(context).colorScheme;
    if (active == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: ActionChip(
        avatar: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text(active.initial,
              style: TextStyle(
                  fontSize: 12, color: scheme.onPrimaryContainer)),
        ),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: Text(active.displayName.isEmpty ? 'Me' : active.displayName,
              overflow: TextOverflow.ellipsis),
        ),
        tooltip: 'Switch profile',
        onPressed: () => _pick(context, ref),
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final profiles = ref.read(profilesProvider).value ?? const <WalkerProfile>[];
    final activeId = ref.read(activeProfileProvider).value?.id;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Who is walking on this phone?',
                    style: Theme.of(c).textTheme.titleMedium),
              ),
            ),
            for (final p in profiles)
              ListTile(
                leading: CircleAvatar(child: Text(p.initial)),
                title: Text(p.displayName.isEmpty ? p.relation.label : p.displayName),
                subtitle: Text(p.relation.label),
                trailing: p.id == activeId ? const Icon(Icons.check) : null,
                onTap: () {
                  ref.read(activeProfileIdProvider.notifier).select(p.id);
                  Navigator.pop(c);
                },
              ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Manage profiles'),
              onTap: () {
                Navigator.pop(c);
                context.pushNamed(RouteNames.profiles);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Centers scrolling content and caps its width on large screens.
class PageContainer extends StatelessWidget {
  const PageContainer({
    super.key,
    required this.child,
    this.maxWidth = AppSpacing.contentMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
