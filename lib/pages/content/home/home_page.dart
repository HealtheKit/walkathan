import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/router/route_names.dart';
import '../../../constants/firebase_constants.dart';
import '../../../models/custom_error.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../utils/error_dialog.dart';
import 'home_provider.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = supabaseClient.auth.currentUser!.id;
    final profileState = ref.watch(profileProvider(uid));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            onPressed: () async {
              try {
                await ref.read(authRepositoryProvider).signout();
              } on CustomError catch (e) {
                if (!context.mounted) return;
                errorDialog(context, e);
              }
            },
            icon: const Icon(Icons.logout),
          ),
          IconButton(
            onPressed: () {
              ref.invalidate(profileProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Colors.blue, // Start color
                Colors.red, // End color
              ],
            ),
          ),
        ),
      ),
      body: profileState.when(
        skipLoadingOnRefresh: false,
        data: (appUser) {
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  Colors.blue,
                  Colors.red,
                ],
              )
            ),
            child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset('assets/images/logo.png', width: 200, height: 200,),
                Text(
                  'Welcome ${appUser.name}',
                  style: const TextStyle(fontSize: 24.0),
                ),
                const SizedBox(height: 20.0),
                const Text(
                  'Your Profile',
                  style: TextStyle(fontSize: 24.0),
                ),
                const SizedBox(height: 10.0),
                Text(
                  'email: ${appUser.email}',
                  style: const TextStyle(fontSize: 16.0),
                ),
                const SizedBox(height: 10.0),
                Text(
                  'id: ${appUser.id}',
                  style: const TextStyle(fontSize: 16.0),
                ),
                const SizedBox(height: 40),
                OutlinedButton(
                  onPressed: () {
                    GoRouter.of(context).goNamed(RouteNames.changePassword);
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.yellow, width: 2), // Gold border
                    foregroundColor: Colors.yellow, // Text color
                  ),
                  child: const Text(
                    'Change Password',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(height: 40),
                OutlinedButton(
                  onPressed: () {
                    GoRouter.of(context).go('/walkHome/$uid');
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.yellow, width: 2), // Gold border
                    foregroundColor: Colors.yellow, // Text color
                  ),
                  child: const Text(
                    'Walkathon Home',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(height: 40),
                OutlinedButton(
                  onPressed: () {
                    GoRouter.of(context).go('/leaderBoard');
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.yellow, width: 2), // Gold border
                    foregroundColor: Colors.yellow, // Text color
                  ),
                  child: const Text(
                    'Leader Board',
                    style: TextStyle(fontSize: 20),
                  ),
                )
              ],
            ),
            ),
          );
        },
        error: (e, _) {
          final error = e is CustomError
              ? e
              : CustomError(code: 'error', message: e.toString(), plugin: '');

          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    error.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: () => ref.invalidate(profileProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        },
        loading: () => const Center(
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
}
