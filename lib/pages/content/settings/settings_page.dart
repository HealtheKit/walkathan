import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/app_config.dart';
import '../../../config/router/route_names.dart';
import '../../../constants/firebase_constants.dart';
import '../../../models/custom_error.dart';
import '../../../providers/profile_providers.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_theme.dart';
import '../../../theme/palette_provider.dart';
import '../../../utils/app_snackbar.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/buttons.dart';

/// Account, privacy explanations, Help & Feedback and account deletion.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _feedback = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  Future<void> _sendFeedback() async {
    if (_feedback.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(accountRepositoryProvider)
          .sendFeedback(_feedback.text);
      if (!mounted) return;
      _feedback.clear();
      showAppSnackBar(context, 'Thanks! Your feedback was sent.');
    } on CustomError catch (e) {
      if (!mounted) return;
      errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteAccount() async {
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'This permanently deletes your login, every profile on it '
                '(including your spouse and children) and all step history. '
                'It cannot be undone.'),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: password,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Confirm your password'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(c).colorScheme.error,
                  foregroundColor: Theme.of(c).colorScheme.onError),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete everything')),
        ],
      ),
    );
    final pw = password.text;
    password.dispose();
    if (confirmed != true || pw.isEmpty) return;
    try {
      await ref.read(accountRepositoryProvider).deleteAccount(pw);
      // Auth state change sends the router back to sign-in.
    } on CustomError catch (e) {
      if (!mounted) return;
      errorDialog(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final email = supabaseClient.auth.currentUser?.email ?? '';

    Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(title, style: text.titleMedium),
              ),
              Card(child: Column(children: children)),
            ],
          ),
        );

    Widget body(String t) => Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(t,
              style:
                  text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: BackButton(onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/home');
          }
        }),
      ),
      body: PageContainer(
        child: ListView(
          padding: AppSpacing.pagePadding,
          children: [
            section('Account', [
              ListTile(
                leading: const Icon(Icons.mail_outline),
                title: const Text('Email'),
                subtitle: Text(email),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.groups_2_outlined),
                title: const Text('Profiles'),
                subtitle: const Text('You, your spouse and children'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.pushNamed(RouteNames.profiles),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.lock_reset),
                title: const Text('Change password'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.goNamed(RouteNames.changePassword),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () => ref.read(authRepositoryProvider).signout(),
              ),
            ]),
            section('Appearance', [
              for (final p in AppPalette.values)
                _PaletteOption(
                  palette: p,
                  selected: ref.watch(paletteProvider) == p,
                  onTap: () => ref.read(paletteProvider.notifier).select(p),
                ),
            ]),
            section('Privacy', [
              body('Your steps are private by default. Here is exactly who '
                  'can see them:'),
              const ListTile(
                  dense: true,
                  leading: Icon(Icons.lock_outline),
                  title: Text('Nobody, by default'),
                  subtitle: Text(
                      'Steps are visible only to the person who walked them.')),
              const ListTile(
                  dense: true,
                  leading: Icon(Icons.emoji_events_outlined),
                  title: Text('Walkathon events'),
                  subtitle: Text(
                      'Name, photo and steps show on event leaderboards.')),
              const ListTile(
                  dense: true,
                  leading: Icon(Icons.group_outlined),
                  title: Text('Friends and groups you join'),
                  subtitle: Text(
                      'They can see your step activity while you are connected.')),
              const ListTile(
                  dense: true,
                  leading: Icon(Icons.location_on_outlined),
                  title: Text('Location stays on your phone'),
                  subtitle: Text(
                      'It is used only to check that you are moving, so '
                      'shaking the phone does not add steps. It is never '
                      'uploaded or shown to anyone.')),
              const ListTile(
                  dense: true,
                  leading: Icon(Icons.shield_outlined),
                  title: Text('Never advertisers'),
                  subtitle: Text(
                      'Health and step data is never used for ads or shared '
                      'with advertising platforms.')),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Change sharing per profile'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.pushNamed(RouteNames.profiles),
              ),
            ]),
            section('Help & Feedback', [
              const ExpansionTile(
                title: Text('Why are my steps not updating?'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.centerLeft,
                children: [
                  Text('Steps sync when the app can read your phone\'s step '
                      'data. Check that activity permission is allowed, open '
                      'the app once, and make sure you are online. Delayed '
                      'syncs fix themselves.'),
                ],
              ),
              const ExpansionTile(
                title: Text('Why can I only add 6 profiles?'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.centerLeft,
                children: [
                  Text('One login holds up to 6 walkers: you, your spouse, '
                      'your children and one other person. Each person walks '
                      'with their own phone.'),
                ],
              ),
              const ExpansionTile(
                title: Text('How do I join the walkathon?'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.centerLeft,
                children: [
                  Text('Members are added by the walkathon administrator. '
                      'Ask them to create your login, then sign in with the '
                      'temporary password you receive.'),
                ],
              ),
              const ExpansionTile(
                title: Text('I forgot my password'),
                childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.centerLeft,
                children: [
                  Text('Use "Forgot password?" on the sign-in screen, or ask '
                      'your administrator to issue a new temporary password.'),
                ],
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.support_agent),
                title: const Text('Contact support'),
                subtitle: const Text(AppConfig.supportEmail),
                trailing: IconButton(
                  tooltip: 'Copy email',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(
                        const ClipboardData(text: AppConfig.supportEmail));
                    if (context.mounted) {
                      showAppSnackBar(context, 'Support email copied');
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _feedback,
                      maxLines: 4,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        labelText: 'Send feedback',
                        helperText:
                            'Includes basic app info (platform), never your steps.',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppButton(
                      label: 'Send feedback',
                      loading: _sending,
                      onPressed: _sendFeedback,
                      variant: AppButtonVariant.outlined,
                    ),
                  ],
                ),
              ),
            ]),
            section('Delete account', [
              body('Deleting your account removes your login, all profiles '
                  'and all step history for good.'),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
                child: OutlinedButton.icon(
                  onPressed: _deleteAccount,
                  style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                      side: BorderSide(color: scheme.error)),
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Delete my account'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// A theme choice with a preview of its own colours.
class _PaletteOption extends StatelessWidget {
  const _PaletteOption({required this.palette, required this.selected, required this.onTap});
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = AppTheme.light(palette);
    final c = preview.colorScheme;
    final gold = preview.extension<BrandColors>()!.gold;
    return Semantics(
      selected: selected,
      button: true,
      child: ListTile(
        onTap: onTap,
        leading: SizedBox(
          width: 56,
          height: 32,
          child: Row(children: [
            for (final color in [c.primary, c.secondary, gold, c.surface])
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(right: 2),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: c.outlineVariant),
                  ),
                ),
              ),
          ]),
        ),
        title: Text(palette.label),
        subtitle: Text(palette.description),
        trailing: selected
            ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
            : null,
      ),
    );
  }
}
