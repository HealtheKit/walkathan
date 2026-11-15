import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/login/login_gate.dart';
import '../../../models/custom_error.dart';
import '../../../models/walker_profile.dart';
import '../../../providers/profile_providers.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/state_widgets.dart';

/// Shown after every sign-in, listing the login's profiles (even when there
/// is only one): "Who is walking on this phone?".
class SelectProfilePage extends ConsumerWidget {
  const SelectProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final lastId = ref.watch(activeProfileProvider).value?.id;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose your profile'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
              onPressed: () => ref.read(authRepositoryProvider).signout(),
              child: const Text('Sign out')),
        ],
      ),
      body: profiles.when(
        loading: () => const LoadingState(),
        error: (e, _) => ErrorState(
          message: e is CustomError ? e.message : 'Could not load profiles.',
          onRetry: () => ref.invalidate(profilesProvider),
        ),
        data: (list) => PageContainer(
          child: ListView(
            padding: AppSpacing.pagePadding,
            children: [
              Text('Who is walking on this phone?', style: text.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Steps from this phone count for the profile you pick. You can '
                'switch later from the name at the top of the screen.',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.lg),
              for (final p in list) ...[
                _Tile(profile: p, last: p.id == lastId),
                const SizedBox(height: AppSpacing.md),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Tile extends ConsumerWidget {
  const _Tile({required this.profile, required this.last});
  final WalkerProfile profile;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final name = profile.displayName.isEmpty ? profile.relation.label : profile.displayName;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Text(profile.initial, style: TextStyle(color: scheme.onPrimaryContainer)),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(last ? '${profile.relation.label} · last used' : profile.relation.label),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => ref.read(loginGateProvider.notifier).choose(profile.id),
      ),
    );
  }
}
