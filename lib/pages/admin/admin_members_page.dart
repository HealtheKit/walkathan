import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/custom_error.dart';
import '../../providers/profile_providers.dart';
import '../../repositories/admin_repository.dart';
import '../../theme/app_spacing.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/error_dialog.dart';
import '../widgets/app_shell.dart';
import '../widgets/state_widgets.dart';

final membersProvider = FutureProvider.autoDispose<List<Member>>(
  (ref) => ref.watch(adminRepositoryProvider).listMembers(),
);

/// Super Admin only: add members, reset passwords, disable or delete.
/// Authorization is enforced server-side; this screen merely hides itself.
class AdminMembersPage extends ConsumerWidget {
  const AdminMembersPage({super.key});

  Future<void> _run(BuildContext context, WidgetRef ref,
      Future<void> Function() action, String success) async {
    try {
      await action();
      ref.invalidate(membersProvider);
      if (context.mounted) showAppSnackBar(context, success);
    } on CustomError catch (e) {
      if (context.mounted) errorDialog(context, e);
    }
  }

  Future<void> _showCredentials(
      BuildContext context, String email, String password) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Share these sign-in details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'This temporary password is shown only once. The member must '
                'choose a new one at first login.'),
            const SizedBox(height: AppSpacing.lg),
            SelectableText('Email: $email'),
            SelectableText('Password: $password',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
            onPressed: () => Clipboard.setData(ClipboardData(
                text: 'Email: $email\nTemporary password: $password')),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(c), child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _addMember(BuildContext context, WidgetRef ref) async {
    final email = TextEditingController();
    final name = TextEditingController();
    final key = GlobalKey<FormState>();
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add a member'),
        content: Form(
          key: key,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Email'),
              validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                      .hasMatch(v?.trim() ?? '')
                  ? null
                  : 'Enter a valid email',
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) =>
                  (v?.trim().isEmpty ?? true) ? 'Name required' : null,
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (key.currentState!.validate()) Navigator.pop(c, true);
              },
              child: const Text('Add')),
        ],
      ),
    );
    final e = email.text.trim();
    final n = name.text.trim();
    email.dispose();
    name.dispose();
    if (go != true || !context.mounted) return;
    try {
      final pw = await ref
          .read(adminRepositoryProvider)
          .createMember(email: e, displayName: n);
      ref.invalidate(membersProvider);
      if (context.mounted) await _showCredentials(context, e, pw);
    } on CustomError catch (err) {
      if (context.mounted) errorDialog(context, err);
    }
  }

  Future<bool> _confirm(
      BuildContext context, String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isSuperAdminProvider);
    final members = ref.watch(membersProvider);
    final repo = ref.watch(adminRepositoryProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Members'),
        leading: BackButton(onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/home');
          }
        }),
        actions: [
          IconButton(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(membersProvider),
              icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: isAdmin.value == true
          ? FloatingActionButton.extended(
              onPressed: () => _addMember(context, ref),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add member'),
            )
          : null,
      body: isAdmin.when(
        loading: () => const LoadingState(),
        error: (err, st) => ErrorState(
            message: 'Could not check your permissions.',
            onRetry: () => ref.invalidate(isSuperAdminProvider)),
        data: (allowed) {
          if (!allowed) {
            return const EmptyState(
              icon: Icons.lock_outline,
              title: 'Super Admins only',
              message: 'Ask a Super Admin if you need to add members.',
            );
          }
          return members.when(
            loading: () => const LoadingState(),
            error: (e, _) => ErrorState(
              message: e is CustomError ? e.message : 'Could not load members.',
              onRetry: () => ref.invalidate(membersProvider),
            ),
            data: (list) {
              if (list.isEmpty) {
                return const EmptyState(
                    icon: Icons.group_add_outlined,
                    title: 'No members yet',
                    message: 'Tap "Add member" to create the first login.');
              }
              return PageContainer(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  itemCount: list.length,
                  separatorBuilder: (ctx, i) =>
                      const SizedBox(height: AppSpacing.md),
                  itemBuilder: (context, i) {
                    final m = list[i];
                    final last = m.lastSignInAt == null
                        ? 'never signed in'
                        : 'last seen ${DateFormat.yMMMd().format(m.lastSignInAt!.toLocal())}';
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.lg),
                        title: Text(m.email,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${m.profileCount} profile${m.profileCount == 1 ? '' : 's'} · $last',
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        leading: m.isDisabled
                            ? Icon(Icons.block, color: scheme.error)
                            : const Icon(Icons.person_outline),
                        trailing: PopupMenuButton<String>(
                          onSelected: (a) async {
                            switch (a) {
                              case 'reset':
                                if (await _confirm(context, 'Reset password?',
                                    'A new temporary password will be issued for ${m.email}.')) {
                                  try {
                                    final pw =
                                        await repo.resetPassword(m.accountId);
                                    if (context.mounted) {
                                      await _showCredentials(
                                          context, m.email, pw);
                                    }
                                  } on CustomError catch (e) {
                                    if (context.mounted) {
                                      errorDialog(context, e);
                                    }
                                  }
                                }
                              case 'toggle':
                                if (context.mounted) {
                                  await _run(
                                      context,
                                      ref,
                                      () => repo.setDisabled(m.accountId,
                                          disabled: !m.isDisabled),
                                      m.isDisabled
                                          ? 'Member enabled'
                                          : 'Member disabled');
                                }
                              case 'delete':
                                if (await _confirm(context, 'Delete member?',
                                        'This permanently deletes ${m.email}, all their profiles and step history.') &&
                                    context.mounted) {
                                  await _run(
                                      context,
                                      ref,
                                      () => repo.deleteMember(m.accountId),
                                      'Member deleted');
                                }
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                                value: 'reset', child: Text('Reset password')),
                            PopupMenuItem(
                                value: 'toggle',
                                child:
                                    Text(m.isDisabled ? 'Enable' : 'Disable')),
                            const PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
