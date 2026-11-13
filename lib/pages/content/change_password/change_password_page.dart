import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/custom_error.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../utils/error_dialog.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_fields.dart';
import '../reauthenticate/reauthenticate_page.dart';
import 'change_password_provider.dart';

class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autovalidateMode = AutovalidateMode.disabled;
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() => _autovalidateMode = AutovalidateMode.always);

    final form = _formKey.currentState;

    if (form == null || !form.validate()) return;

    ref.read(changePasswordProvider.notifier).changePassword(
          _passwordController.text.trim(),
        );
  }

  void processSuccessCase() async {
    try {
      await ref.read(authRepositoryProvider).signout();
    } on CustomError catch (e) {
      if (!mounted) return;
      errorDialog(context, e);
    }
  }

  void processRequiresRecentLogin() async {
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);

    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) {
          return const ReauthenticatePage();
        },
      ),
    );

    if (result == 'success') {
      // Context may be unmounted after the await; use the captured
      // messenger/theme with the shared snackbar styling.
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 20, color: theme.colorScheme.onInverseSurface),
                const SizedBox(width: 12),
                const Expanded(child: Text('Successfully reauthenticated')),
              ],
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<void>>(
      changePasswordProvider,
      (previous, next) {
        next.whenOrNull(error: (e, st) {
          final err = e as CustomError;

          if (err.code == 'requires-recent-login') {
            processRequiresRecentLogin();
          } else {
            errorDialog(context, err);
          }
        }, data: (_) {
          processSuccessCase();
        });
      },
    );

    final chgPwdState = ref.watch(changePasswordProvider);

    return AuthLayout(
      appBar: AppBar(title: const Text('Change Password')),
      title: 'Choose a new password',
      subtitle: 'For security, you will be signed out once it changes.',
      showLogo: false,
      children: [
        Form(
          key: _formKey,
          autovalidateMode: _autovalidateMode,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
              AppButton(
                label: 'Change Password',
                loading: chgPwdState.isLoading,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
