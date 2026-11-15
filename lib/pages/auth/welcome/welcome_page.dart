import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/custom_error.dart';
import '../../../providers/profile_providers.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_fields.dart';

/// Shown once after the first login: replace the temporary password issued
/// by the administrator and accept the privacy notice.
class WelcomePage extends ConsumerStatefulWidget {
  const WelcomePage({super.key});

  @override
  ConsumerState<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends ConsumerState<WelcomePage> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;
  bool _consent = false;
  bool _consentError = false;
  bool _submitting = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit(bool mustChange) async {
    setState(() => _autovalidate = AutovalidateMode.always);
    final valid = _formKey.currentState?.validate() ?? false;
    setState(() => _consentError = !_consent);
    if (!valid || !_consent) return;

    setState(() => _submitting = true);
    try {
      await ref.read(accountRepositoryProvider).completeFirstLogin(
            newPassword:
                mustChange ? _passwordController.text.trim() : null,
          );
      // The auth stream fires; the router then moves on to Home.
    } on CustomError catch (e) {
      if (!mounted) return;
      errorDialog(context, e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mustChange = ref.watch(accountRepositoryProvider).mustChangePassword;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return AuthLayout(
      title: 'Welcome to the walkathon',
      subtitle: mustChange
          ? 'Choose your own password to finish setting up.'
          : 'One quick step before you start.',
      children: [
        Form(
          key: _formKey,
          autovalidateMode: _autovalidate,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mustChange) ...[
                PasswordFormField(
                  passwordController: _passwordController,
                  labelText: 'New password',
                ),
                const SizedBox(height: AppSpacing.lg),
                ConfirmPasswordFormField(
                  passwordController: _passwordController,
                  labelText: 'Confirm new password',
                ),
                const SizedBox(height: AppSpacing.xl),
              ],
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainer,
                  borderRadius:
                      BorderRadius.circular(AppSpacing.radiusField),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('How your steps are shared', style: text.titleSmall),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Your steps are private by default. During walkathon '
                      'events, each walker\'s name, photo and step count '
                      'appear on event leaderboards for other members. '
                      'Groups and friends you join can also see your steps. '
                      'You can review this any time in Settings.\n\n'
                      'You manage the profiles on this account (for example '
                      'your spouse and children), so please make sure you '
                      'are allowed to share their details.',
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _consent,
                onChanged: (v) => setState(() {
                  _consent = v ?? false;
                  _consentError = false;
                }),
                title: const Text('I understand and agree'),
                subtitle: _consentError
                    ? Text('Please accept to continue',
                        style: TextStyle(color: scheme.error))
                    : null,
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: 'Continue',
                loading: _submitting,
                onPressed: () => _submit(mustChange),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextButton(
                label: 'Sign out',
                onPressed: _submitting
                    ? null
                    : () => ref.read(authRepositoryProvider).signout(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
