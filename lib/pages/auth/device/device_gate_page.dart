import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/login/login_gate.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/app_shell.dart';

/// Shown right after sign-in while this phone is checked. A phone the login
/// has used before passes in a moment; a NEW phone waits here until a Super
/// Admin or an organizer of the member's event approves it.
class DeviceGatePage extends ConsumerWidget {
  const DeviceGatePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = ref.watch(loginGateProvider);
    final notifier = ref.read(loginGateProvider.notifier);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    final (IconData icon, String title, String message, List<Widget> actions) =
        switch (gate.stage) {
      LoginStage.devicePending => (
          Icons.phonelink_lock_outlined,
          'Waiting for approval',
          'This is a new phone for your login. A Super Admin or an organizer '
              'of your event must approve it before it can be used. This page '
              'continues by itself once they do.',
          [
            FilledButton(onPressed: notifier.recheck, child: const Text('Check again')),
          ]
        ),
      LoginStage.deviceRejected => (
          Icons.block_outlined,
          'Phone not approved',
          gate.note == null || gate.note!.isEmpty
              ? 'An organizer did not approve this phone. If this is a mistake, ask again or contact your organizer.'
              : 'An organizer did not approve this phone: “${gate.note}”',
          [
            FilledButton(onPressed: notifier.askAgain, child: const Text('Ask again')),
          ]
        ),
      LoginStage.deviceError => (
          Icons.cloud_off_outlined,
          'Can\'t reach the server',
          'This phone has to be checked online the first time. Check your '
              'connection and try again.',
          [
            FilledButton(onPressed: notifier.recheck, child: const Text('Try again')),
          ]
        ),
      _ => (Icons.phone_android, 'Checking this phone…', '', const <Widget>[]),
    };

    return Scaffold(
      body: SafeArea(
        child: PageContainer(
          child: Center(
            child: SingleChildScrollView(
              padding: AppSpacing.pagePadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (gate.stage == LoginStage.checking)
                    const CircularProgressIndicator()
                  else
                    Icon(icon, size: 64, color: scheme.primary),
                  const SizedBox(height: AppSpacing.lg),
                  Text(title, style: text.titleLarge, textAlign: TextAlign.center),
                  if (message.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text(message,
                        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  ...actions,
                  if (gate.stage != LoginStage.checking)
                    TextButton(
                      onPressed: () => ref.read(authRepositoryProvider).signout(),
                      child: const Text('Sign out'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
