import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/firebase_constants.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/app_shell.dart';
import './leader_board_provider.dart';
import './leaderboard_widgets.dart';

enum _Board { men, women }

class LeaderBoardPage extends ConsumerStatefulWidget {
  const LeaderBoardPage({super.key});

  @override
  ConsumerState<LeaderBoardPage> createState() => _LeaderBoardPageState();
}

class _LeaderBoardPageState extends ConsumerState<LeaderBoardPage> {
  _Board _selected = _Board.men;

  void _invalidateBoth() {
    ref.invalidate(leaderboardMaleDataProvider);
    ref.invalidate(leaderboardFeMaleDataProvider);
  }

  Future<void> _refresh() async {
    _invalidateBoth();
    try {
      await Future.wait([
        ref.read(leaderboardMaleDataProvider.future),
        ref.read(leaderboardFeMaleDataProvider.future),
      ]);
    } catch (_) {
      // Errors surface in each section's own error state.
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = supabaseClient.auth.currentUser?.id;
    final male = ref.watch(leaderboardMaleDataProvider);
    final female = ref.watch(leaderboardFeMaleDataProvider);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final wide = context.isExpanded;

    final menSection = LeaderboardSection(
      title: 'Top Men',
      icon: Icons.emoji_events,
      state: male,
      currentUserId: uid,
      onRetry: () => ref.invalidate(leaderboardMaleDataProvider),
    );
    final womenSection = LeaderboardSection(
      title: 'Top Women',
      icon: Icons.emoji_events,
      state: female,
      currentUserId: uid,
      onRetry: () => ref.invalidate(leaderboardFeMaleDataProvider),
    );

    return AppShell(
      current: AppTab.leaderboard,
      title: 'Leader Board',
      onRefresh: _invalidateBoth,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: PageContainer(
          maxWidth: wide ? 1040 : AppSpacing.contentMaxWidth,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: AppSpacing.pagePadding,
            children: [
              Text(
                'Top walkers over the last 30 days',
                style:
                    text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: menSection),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(child: womenSection),
                  ],
                )
              else ...[
                SegmentedButton<_Board>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _Board.men, label: Text('Men')),
                    ButtonSegment(value: _Board.women, label: Text('Women')),
                  ],
                  selected: {_selected},
                  onSelectionChanged: (s) =>
                      setState(() => _selected = s.first),
                ),
                const SizedBox(height: AppSpacing.lg),
                _selected == _Board.men ? menSection : womenSection,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
