import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/firebase_constants.dart';
import '../../../models/custom_error.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../theme/app_spacing.dart';
import '../../../utils/error_dialog.dart';
import '../../widgets/auth_layout.dart';
import '../../widgets/buttons.dart';

// With Supabase, email verification is handled via confirmation links.
// If "Enable email confirmations" is on in the Supabase dashboard,
// users cannot sign in until they click the confirmation link.
// This page is kept as a fallback informational screen.

class VerifyEmailPage extends ConsumerWidget {
  const VerifyEmailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final email = supabaseClient.auth.currentUser?.email ?? '';

    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return AuthLayout(
      appBar: AppBar(title: const Text('Email Verification')),
      title: 'Check your inbox',
      subtitle: 'A verification email has been sent to',
      showLogo: false,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppSpacing.radiusField),
          ),
          child: Row(
            children: [
              Icon(Icons.mark_email_unread_outlined,
                  color: scheme.onPrimaryContainer),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  email,
                  style: text.titleMedium
                      ?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Please click the link in the email to verify your account.',
          style: text.bodyLarge,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text.rich(
          TextSpan(
            text: "Can't find it? Check your ",
            children: [
              TextSpan(
                text: 'spam',
                style: TextStyle(
                  color: scheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(text: ' folder.'),
            ],
          ),
          style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.xl),
        AppButton(
          label: 'Cancel',
          variant: AppButtonVariant.outlined,
          onPressed: () async {
            try {
              await ref.read(authRepositoryProvider).signout();
            } on CustomError catch (e) {
              if (!context.mounted) return;
              errorDialog(context, e);
            }
          },
        ),
      ],
    );
  }
}
