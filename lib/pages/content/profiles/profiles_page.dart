import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/app_config.dart';
import '../../../config/router/route_names.dart';
import '../../../models/custom_error.dart';
import '../../../models/walker_profile.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/state_widgets.dart';

/// Household profiles: self, spouse, children (max 6 per login).
class ProfilesPage extends ConsumerWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final activeId = ref.watch(activeProfileProvider).value?.id;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profiles'),
        leading: BackButton(onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/home');
          }
        }),
      ),
      body: profiles.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load profiles.',
          onRetry: () => ref.invalidate(profilesProvider),
        ),
        data: (list) {
          final full = list.length >= AppConfig.maxProfilesPerAccount;
          return PageContainer(
            child: ListView(
              padding: AppSpacing.pagePadding,
              children: [
                Text(
                  'One login can hold up to ${AppConfig.maxProfilesPerAccount} '
                  'walkers: you, your spouse and your children. Each person '
                  'walks with their own phone and has their own steps and goal.',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.lg),
                for (final p in list) ...[
                  _ProfileTile(profile: p, active: p.id == activeId),
                  const SizedBox(height: AppSpacing.md),
                ],
                const SizedBox(height: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: full
                      ? null
                      : () => context.pushNamed(RouteNames.profileNew),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: Text(full
                      ? 'Profile limit reached (${list.length}/${AppConfig.maxProfilesPerAccount})'
                      : 'Add a profile (${list.length}/${AppConfig.maxProfilesPerAccount})'),
                ),
                if (list.length > 1) ...[
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: () => context.pushNamed(RouteNames.profileTransfer),
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Got a new phone? Move a profile'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.profile, required this.active});

  final WalkerProfile profile;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text(profile.initial,
              style: TextStyle(color: scheme.onPrimaryContainer)),
        ),
        title: Text(
          profile.displayName.isEmpty ? '(no name yet)' : profile.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${profile.relation.label} · goal ${profile.dailyGoal} steps',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        trailing: active
            ? Chip(
                label: const Text('This device'),
                visualDensity: VisualDensity.compact,
                backgroundColor: scheme.primaryContainer,
              )
            : IconButton(
                tooltip: 'Use on this device',
                icon: const Icon(Icons.phone_android),
                onPressed: () => ref
                    .read(activeProfileIdProvider.notifier)
                    .select(profile.id),
              ),
        onTap: () => context.pushNamed(RouteNames.profileEdit,
            pathParameters: {'profileId': profile.id}),
      ),
    );
  }
}
