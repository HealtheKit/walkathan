import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/custom_error.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../utils/error_dialog.dart';
import '../../../theme/app_spacing.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_fields.dart';

class ReauthenticatePage extends ConsumerStatefulWidget {
  const ReauthenticatePage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _ReauthenticatePageState();
}

class _ReauthenticatePageState extends ConsumerState<ReauthenticatePage> {
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autovalidateMode = AutovalidateMode.disabled;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool submitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() async {
    setState(() {
      _autovalidateMode = AutovalidateMode.always;
    });

    final form = _formKey.currentState;

    if (form == null || !form.validate()) return;

    setState(() {
      submitting = true;
    });

    try {
      final navigator = Navigator.of(context);

      await ref.read(authRepositoryProvider).reauthenticateWithCredential(
            _emailController.text.trim(),
            _passwordController.text.trim(),
          );

      setState(() {
        submitting = false;
      });

      navigator.pop('success');
    } on CustomError catch (e) {
      setState(() {
        submitting = false;
      });
      if (!mounted) return;
      errorDialog(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      appBar: AppBar(title: const Text('Reauthenticate')),
      title: 'Confirm it\'s you',
      subtitle:
          'This is a security-sensitive operation. Please sign in again to continue.',
      showLogo: false,
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
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: 'Reauthenticate',
                loading: submitting,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
