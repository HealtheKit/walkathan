import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/firebase_constants.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/app_shell.dart';
import './leader_board_provider.dart';
import './leaderboard_widgets.dart';

class FeMaleBoardPage extends ConsumerStatefulWidget {
  const FeMaleBoardPage({super.key});

  @override
  ConsumerState<FeMaleBoardPage> createState() => _FeMaleBoardPageState();
}

class _FeMaleBoardPageState extends ConsumerState<FeMaleBoardPage> {
  @override
  Widget build(BuildContext context) {
    final uid = supabaseClient.auth.currentUser?.id;
    final state = ref.watch(leaderboardFeMaleDataProvider);

    return AppShell(
      current: AppTab.leaderboard,
      title: 'Top Women',
      onRefresh: () => ref.invalidate(leaderboardFeMaleDataProvider),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(leaderboardFeMaleDataProvider);
          try {
            await ref.read(leaderboardFeMaleDataProvider.future);
          } catch (_) {
            // Shown in the section's error state.
          }
        },
        child: PageContainer(
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: AppSpacing.pagePadding,
            children: [
              LeaderboardSection(
                title: 'Top Women',
                icon: Icons.emoji_events,
                state: state,
                currentUserId: uid,
                onRetry: () => ref.invalidate(leaderboardFeMaleDataProvider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
