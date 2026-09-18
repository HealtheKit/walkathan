import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../utils/error_dialog.dart';
import '../../../models/custom_error.dart';
import '../home/home_provider.dart';
import 'package:go_router/go_router.dart';
import '../../../constants/firebase_constants.dart';
import './leader_board_provider.dart';

class FeMaleBoardPage extends ConsumerStatefulWidget {
  const FeMaleBoardPage({super.key});

  @override
  _FeMaleBoardPageState createState() => _FeMaleBoardPageState();
}

class _FeMaleBoardPageState extends ConsumerState<FeMaleBoardPage> {

  @override
  Widget build(BuildContext context) {
    final uid = supabaseClient.auth.currentUser!.id;
    final profileState = ref.watch(profileProvider(uid));
    final leaderBoardState = ref.watch(leaderboardFeMaleDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leader Board'),
        backgroundColor: Colors.blue,
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
      ),
      body: profileState.when(
        skipLoadingOnRefresh: false,
        data: (appUser) {
          return SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Padding(
                  padding: EdgeInsets.all(20.0),
                  child: Text(
                    'Top Women',
                    style: TextStyle(fontSize: 24.0),
                  ),
                ),
                leaderBoardState.when(
                  data: (leaderboardData) => _buildLeaderBoard(leaderboardData),
                  error: (error, stackTrace) => Center(child: Text('Error loading leaderboard: $error')),
                  loading: () => const Center(child: CircularProgressIndicator()),
                ),
                const SizedBox(height: 40),
                OutlinedButton(
                  onPressed: () {
                    GoRouter.of(context).go('/walkHome/$uid');
                  },
                  child: const Text(
                    'Walkathon Home',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
              ],
            ),
          );
        },
        error: (e, _) {
          final error = e is CustomError
              ? e
              : CustomError(code: 'error', message: e.toString(), plugin: '');
          return Center(
            child: Text(
              error.message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.red,
                fontSize: 18,
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

  Widget _buildLeaderBoard(List<Map<String, dynamic>> leaderboardData) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.5, // Adjust based on your UI needs
      child: ListView.builder(
        itemCount: leaderboardData.length,
        itemBuilder: (context, index) {
          final entry = leaderboardData[index];
          return ListTile(
            title: Text(entry['name'] ?? 'Anonymous'),
            trailing: Text(entry['totalSteps'].toString()),
          );
        },
      ),
    );
  }
}