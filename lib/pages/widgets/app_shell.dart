import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/router/route_names.dart';
import '../../constants/firebase_constants.dart';
import '../../models/custom_error.dart';
import '../../repositories/auth_repository_provider.dart';
import '../../theme/app_spacing.dart';
import '../../utils/error_dialog.dart';

enum AppTab { home, walk, leaderboard }

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
    (tab: AppTab.leaderboard, icon: Icons.emoji_events_outlined, selected: Icons.emoji_events, label: 'Leaderboard'),
  ];

  void _go(BuildContext context, AppTab tab) {
    if (tab == current) return;
    switch (tab) {
      case AppTab.home:
        context.go('/home');
      case AppTab.walk:
        final uid = supabaseClient.auth.currentUser!.id;
        context.go('/walkHome/$uid');
      case AppTab.leaderboard:
        context.go('/leaderBoard');
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

    final appBar = AppBar(
      title: Text(title),
      actions: [
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
              case _MenuAction.changePassword:
                context.goNamed(RouteNames.changePassword);
              case _MenuAction.signOut:
                _signOut(context, ref);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _MenuAction.changePassword,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.lock_reset),
                title: Text('Change password'),
              ),
            ),
            PopupMenuItem(
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
              onDestinationSelected: (i) => _go(context, _destinations[i].tab),
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
            Expanded(child: SafeArea(child: body)),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: SafeArea(top: false, bottom: false, child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => _go(context, _destinations[i].tab),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

enum _MenuAction { changePassword, signOut }

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
