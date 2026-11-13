import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../constants/firebase_constants.dart';
import '../../../models/app_user.dart';
import '../../../models/custom_error.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/state_widgets.dart';
import 'home_provider.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = supabaseClient.auth.currentUser!.id;
    final profileState = ref.watch(profileProvider(uid));

    return AppShell(
      current: AppTab.home,
      title: 'Home',
      onRefresh: () => ref.invalidate(profileProvider),
      body: profileState.when(
        skipLoadingOnRefresh: false,
        data: (appUser) => _HomeContent(appUser: appUser, uid: uid),
        error: (e, _) {
          final error = e is CustomError
              ? e
              : CustomError(code: 'error', message: e.toString(), plugin: '');
          return ErrorState(
            message: error.message,
            onRetry: () => ref.invalidate(profileProvider),
          );
        },
        loading: () => const PageContainer(child: _HomeSkeleton()),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({required this.appUser, required this.uid});

  final AppUser appUser;
  final String uid;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final initial =
        appUser.name.trim().isEmpty ? '?' : appUser.name.trim()[0].toUpperCase();

    final cards = [
      _ActionCard(
        icon: Icons.directions_walk,
        title: 'Walkathon Home',
        description: 'Track your steps and activity live.',
        onTap: () => GoRouter.of(context).go('/walkHome/$uid'),
      ),
      _ActionCard(
        icon: Icons.emoji_events,
        title: 'Leader Board',
        description: 'See the top walkers over the last 30 days.',
        onTap: () => GoRouter.of(context).go('/leaderBoard'),
      ),
    ];

    return PageContainer(
      child: ListView(
        padding: AppSpacing.pagePadding,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  initial,
                  style: text.headlineSmall
                      ?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Welcome back', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    Text(
                      appUser.name,
                      style: text.headlineSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      appUser.email,
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Jump in', style: text.titleMedium),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 560) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(child: cards[1]),
                  ],
                );
              }
              return Column(
                children: [
                  cards[0],
                  const SizedBox(height: AppSpacing.md),
                  cards[1],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusField),
                ),
                child: Icon(icon, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppSpacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(
            children: [
              SkeletonBox(width: 64, height: 64, radius: 32),
              SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 90, height: 14),
                    SizedBox(height: 8),
                    SkeletonBox(width: 180, height: 22),
                    SizedBox(height: 8),
                    SkeletonBox(width: 140, height: 14),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.xl),
          SkeletonBox(height: 80, radius: AppSpacing.radiusCard),
          SizedBox(height: AppSpacing.md),
          SkeletonBox(height: 80, radius: AppSpacing.radiusCard),
        ],
      ),
    );
  }
}
