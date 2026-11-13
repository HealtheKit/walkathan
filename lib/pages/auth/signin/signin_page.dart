import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/router/route_names.dart';
import '../../../models/custom_error.dart';
import '../../../utils/error_dialog.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_fields.dart';
import 'signin_provider.dart';

class SigninPage extends ConsumerStatefulWidget {
  const SigninPage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SigninPageState();
}

class _SigninPageState extends ConsumerState<SigninPage> {
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autovalidateMode = AutovalidateMode.disabled;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() {
      _autovalidateMode = AutovalidateMode.always;
    });

    final form = _formKey.currentState;

    if (form == null || !form.validate()) return;

    ref.read(signinProvider.notifier).signin(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<void>>(
      signinProvider,
      (prev, next) {
        next.whenOrNull(
          error: (e, st) => errorDialog(
            context,
            (e as CustomError),
          ),
        );
      },
    );

    final signinState = ref.watch(signinProvider);

    return AuthLayout(
      title: 'Welcome back',
      subtitle: 'Sign in to track your steps for the TEF Walkathon.',
      children: [
        Form(
          key: _formKey,
          autovalidateMode: _autovalidateMode,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmailFormField(emailController: _emailController),
              const SizedBox(height: AppSpacing.lg),
              PasswordFormField(
                passwordController: _passwordController,
                labelText: 'Password',
              ),
              Align(
                alignment: Alignment.centerRight,
                child: AppTextButton(
                  label: 'Forgot password?',
                  onPressed: signinState.isLoading
                      ? null
                      : () => context.goNamed(RouteNames.resetPassword),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Sign In',
                loading: signinState.isLoading,
                onPressed: _submit,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        AuthFooter(
          prompt: 'Not a member?',
          action: AppTextButton(
            label: 'Sign up',
            onPressed: signinState.isLoading
                ? null
                : () => context.goNamed(RouteNames.signup),
          ),
        ),
      ],
    );
  }
}
