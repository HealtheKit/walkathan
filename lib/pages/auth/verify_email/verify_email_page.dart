import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../constants/firebase_constants.dart';
import '../../../models/custom_error.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../utils/error_dialog.dart';

// With Supabase, email verification is handled via confirmation links.
// If "Enable email confirmations" is on in the Supabase dashboard,
// users cannot sign in until they click the confirmation link.
// This page is kept as a fallback informational screen.

class VerifyEmailPage extends ConsumerWidget {
  const VerifyEmailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final email = supabaseClient.auth.currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Email Verification'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text('A verification email has been sent to'),
                  Text(email),
                  const SizedBox(height: 10),
                  const Text('Please click the link in the email to verify.'),
                  const SizedBox(height: 10),
                  const Text('If you cannot find the verification email,'),
                  RichText(
                    text: TextSpan(
                      text: 'Please check ',
                      style: DefaultTextStyle.of(context)
                          .style
                          .copyWith(fontSize: 18),
                      children: const [
                        TextSpan(
                          text: 'SPAM',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextSpan(text: ' folder.'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              onPressed: () async {
                try {
                  await ref.read(authRepositoryProvider).signout();
                } on CustomError catch (e) {
                  if (!context.mounted) return;
                  errorDialog(context, e);
                }
              },
              child: const Text(
                'CANCEL',
                style: TextStyle(fontSize: 20.0),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
