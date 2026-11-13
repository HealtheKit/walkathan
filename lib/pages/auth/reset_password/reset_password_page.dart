import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/router/route_names.dart';
import '../../../models/custom_error.dart';
import '../../../utils/error_dialog.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/app_snackbar.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_fields.dart';

import 'reset_password_provider.dart';

class ResetPasswordPage extends ConsumerStatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _ResetPasswordPageState();
}

class _ResetPasswordPageState extends ConsumerState<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autovalidateMode = AutovalidateMode.disabled;
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() => _autovalidateMode = AutovalidateMode.always);

    final form = _formKey.currentState;

    if (form == null || !form.validate()) return;

    ref.read(resetPasswordProvider.notifier).resetPassword(
          email: _emailController.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<void>>(
      resetPasswordProvider,
      (previous, next) {
        next.whenOrNull(
          error: (e, st) => errorDialog(
            context,
            e as CustomError,
          ),
          data: (_) {
            showAppSnackBar(context, 'Password reset email has been sent');
            GoRouter.of(context).goNamed(RouteNames.signin);
          },
        );
      },
    );

    final resetPwdState = ref.watch(resetPasswordProvider);

    return AuthLayout(
      title: 'Reset your password',
      subtitle: "Enter your email and we'll send you a reset link.",
      children: [
        Form(
          key: _formKey,
          autovalidateMode: _autovalidateMode,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmailFormField(emailController: _emailController),
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: 'Send reset link',
                loading: resetPwdState.isLoading,
                onPressed: _submit,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        AuthFooter(
          prompt: 'Remember your password?',
          action: AppTextButton(
            label: 'Sign in',
            onPressed: resetPwdState.isLoading
                ? null
                : () => context.goNamed(RouteNames.signin),
          ),
        ),
      ],
    );
  }
}
