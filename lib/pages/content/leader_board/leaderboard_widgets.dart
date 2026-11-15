import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../models/custom_error.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/state_widgets.dart';

/// Circular rank marker: gold/silver/bronze for the podium, neutral after.
class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.rank});

  /// 1-based rank.
  final int rank;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final scheme = Theme.of(context).colorScheme;

    final Color? medal = switch (rank) {
      1 => brand.gold,
      2 => brand.silver,
      3 => brand.bronze,
      _ => null,
    };

    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: medal ?? scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$rank',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: medal != null ? brand.onMedal : scheme.onSurfaceVariant,
              fontFeatures: AppTheme.tabularFigures,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class LeaderboardTile extends StatelessWidget {
  const LeaderboardTile({
    super.key,
    required this.rank,
    required this.name,
    required this.steps,
    this.isCurrentUser = false,
    this.valueText,
  });

  final int rank;
  final String name;

  /// Replaces "N steps" when the board ranks by another metric.
  final String? valueText;

  /// Null = the count is hidden (Mystery Mode); only the rank shows.
  final int? steps;
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final hidden = steps == null;
    final formatted = hidden ? 'hidden' : NumberFormat.decimalPattern().format(steps);

    return Semantics(
      label:
          'Rank $rank, $name${isCurrentUser ? ', you' : ''}, '
          '${hidden ? 'steps hidden until tomorrow' : valueText ?? '$formatted steps'}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        color: isCurrentUser
            ? scheme.primaryContainer.withValues(alpha: .55)
            : null,
        child: Row(
          children: [
            RankBadge(rank: rank),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: name,
                  children: [
                    if (isCurrentUser)
                      TextSpan(
                        text: '  You',
                        style: text.labelMedium
                            ?.copyWith(color: scheme.primary),
                      ),
                  ],
                ),
                style: text.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            if (hidden)
              Icon(Icons.visibility_off_outlined,
                  size: 20, color: scheme.onSurfaceVariant)
            else
              // Capped width: at large text scales the figure shrinks to fit
              // instead of pushing the row past the card edge.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        valueText ?? formatted,
                        style: text.titleMedium?.copyWith(
                          fontFeatures: AppTheme.tabularFigures,
                        ),
                      ),
                      if (valueText == null) const SizedBox(width: 4),
                      if (valueText == null)
                      Text(
                        'steps',
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A titled card listing one leaderboard, handling its own loading, empty
/// and error states.
class LeaderboardSection extends StatelessWidget {
  const LeaderboardSection({
    super.key,
    required this.title,
    required this.icon,
    required this.state,
    required this.currentUserId,
    required this.onRetry,
  });

  final String title;
  final IconData icon;
  final AsyncValue<List<Map<String, dynamic>>> state;
  final String? currentUserId;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text(title, style: text.titleLarge),
              ],
            ),
          ),
          const Divider(),
          state.when(
            data: (entries) {
              if (entries.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: EmptyState(
                    icon: Icons.directions_walk,
                    title: 'No steps yet',
                    message: 'Be the first to get on the board.',
                  ),
                );
              }
              return Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) const Divider(indent: 64),
                    LeaderboardTile(
                      rank: i + 1,
                      name: (entries[i]['name'] ?? 'Anonymous').toString(),
                      steps: (entries[i]['totalSteps'] as num?)?.toInt() ?? 0,
                      isCurrentUser: currentUserId != null &&
                          entries[i]['userId'] == currentUserId,
                    ),
                  ],
                ],
              );
            },
            error: (error, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: ErrorState(
                title: "Couldn't load leaderboard",
                message: error is CustomError
                    ? error.message
                    : 'Check your connection and try again.',
                onRetry: onRetry,
              ),
            ),
            loading: () => const _LeaderboardSkeleton(),
          ),
        ],
      ),
    );
  }
}

class _LeaderboardSkeleton extends StatelessWidget {
  const _LeaderboardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading leaderboard',
      child: Column(
        children: [
          for (var i = 0; i < 5; i++)
            const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Row(
                children: [
                  SkeletonBox(width: 36, height: 36, radius: 18),
                  SizedBox(width: AppSpacing.md),
                  Expanded(child: SkeletonBox(height: 16)),
                  SizedBox(width: AppSpacing.xl),
                  SkeletonBox(width: 56, height: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
