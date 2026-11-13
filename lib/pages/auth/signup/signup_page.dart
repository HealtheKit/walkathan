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
import 'signup_provider.dart';

class SignupPage extends ConsumerStatefulWidget {
  const SignupPage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SignupPageState();
}

class _SignupPageState extends ConsumerState<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autovalidateMode = AutovalidateMode.disabled;
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _genderController = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _genderController.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() {
      _autovalidateMode = AutovalidateMode.always;
    });

    final form = _formKey.currentState;

    if (form == null || !form.validate()) return;

    ref.read(signupProvider.notifier).signup(
          name: _nameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
          gender: _genderController.value.toString()
        );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<void>>(
      signupProvider,
      (previous, next) {
        next.whenOrNull(
          error: (e, st) => errorDialog(
            context,
            (e as CustomError),
          ),
        );
      },
    );

    final signupState = ref.watch(signupProvider);

    return AuthLayout(
      title: 'Create your account',
      subtitle: 'Join the walk and see where you rank.',
      children: [
        Form(
          key: _formKey,
          autovalidateMode: _autovalidateMode,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NameFormField(nameController: _nameController),
              const SizedBox(height: AppSpacing.lg),
              EmailFormField(emailController: _emailController),
              const SizedBox(height: AppSpacing.lg),
              PasswordFormField(
                passwordController: _passwordController,
                labelText: 'Password',
              ),
              const SizedBox(height: AppSpacing.lg),
              ConfirmPasswordFormField(
                passwordController: _passwordController,
                labelText: 'Confirm password',
              ),
              const SizedBox(height: AppSpacing.lg),
              GenderFormField(genderController: _genderController),
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: 'Sign Up',
                loading: signupState.isLoading,
                onPressed: _submit,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        AuthFooter(
          prompt: 'Already a member?',
          action: AppTextButton(
            label: 'Sign in',
            onPressed: signupState.isLoading
                ? null
                : () => GoRouter.of(context).goNamed(RouteNames.signin),
          ),
        ),
      ],
    );
  }
}
