import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/firebase_constants.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/app_shell.dart';
import './leader_board_provider.dart';
import './leaderboard_widgets.dart';

class MaleBoardPage extends ConsumerStatefulWidget {
  const MaleBoardPage({super.key});

  @override
  ConsumerState<MaleBoardPage> createState() => _MaleBoardPageState();
}

class _MaleBoardPageState extends ConsumerState<MaleBoardPage> {
  @override
  Widget build(BuildContext context) {
    final uid = supabaseClient.auth.currentUser?.id;
    final state = ref.watch(leaderboardMaleDataProvider);

    return AppShell(
      current: AppTab.leaderboard,
      title: 'Top Men',
      onRefresh: () => ref.invalidate(leaderboardMaleDataProvider),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(leaderboardMaleDataProvider);
          try {
            await ref.read(leaderboardMaleDataProvider.future);
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
                title: 'Top Men',
                icon: Icons.emoji_events,
                state: state,
                currentUserId: uid,
                onRetry: () => ref.invalidate(leaderboardMaleDataProvider),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
