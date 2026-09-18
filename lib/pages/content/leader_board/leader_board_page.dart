import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../utils/error_dialog.dart';
import '../../../models/custom_error.dart';
import '../home/home_provider.dart';
import 'package:go_router/go_router.dart';
import '../../../constants/firebase_constants.dart';
import './leader_board_provider.dart';

class LeaderBoardPage extends ConsumerStatefulWidget {

  const LeaderBoardPage({super.key});

  @override
  _LeaderBoardPageState createState() => _LeaderBoardPageState();
}

class _LeaderBoardPageState extends ConsumerState<LeaderBoardPage> {

  @override
  Widget build(BuildContext context) {
    final uid = supabaseClient.auth.currentUser!.id;
    final profileState = ref.watch(profileProvider(uid));
    final maleLeaderBoardState = ref.watch(leaderboardMaleDataProvider);
    final femaleLeaderBoardState = ref.watch(leaderboardFeMaleDataProvider);

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
              ref.invalidate(leaderboardMaleDataProvider);
              ref.invalidate(leaderboardFeMaleDataProvider);
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
                Colors.blue,
                Colors.red,
              ],
            ),
          ),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/images/leaderhome.png'),
            fit: BoxFit.cover,
          ),
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              Colors.blue,
              Colors.red,
            ],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              profileState.when(
                data: (appUser) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: Text(
                    'Welcome ${appUser.name}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 28.0, color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                error: (e, _) => const SizedBox.shrink(),
                loading: () => const SizedBox.shrink(),
              ),
              const SizedBox(height: 10),
              // Top Men Section
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text(
                        'Top Men',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      maleLeaderBoardState.when(
                        data: (data) => _buildLeaderBoard(data),
                        error: (error, _) => Text('Error: $error', style: const TextStyle(color: Colors.red)),
                        loading: () => const Padding(
                          padding: EdgeInsets.all(20.0),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Top Women Section
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text(
                        'Top Women',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      femaleLeaderBoardState.when(
                        data: (data) => _buildLeaderBoard(data),
                        error: (error, _) => Text('Error: $error', style: const TextStyle(color: Colors.red)),
                        loading: () => const Padding(
                          padding: EdgeInsets.all(20.0),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 30),
              Center(
                child: OutlinedButton(
                  onPressed: () {
                    GoRouter.of(context).go('/walkHome/$uid');
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white, width: 2.0),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(
                    'Walkathon Home',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeaderBoard(List<Map<String, dynamic>> leaderboardData) {
    if (leaderboardData.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12.0),
        child: Text('No data yet', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: leaderboardData.length,
      itemBuilder: (context, index) {
        final entry = leaderboardData[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: index == 0
                ? Colors.amber
                : index == 1
                    ? Colors.grey[400]
                    : index == 2
                        ? Colors.brown[300]
                        : Colors.blue[100],
            child: Text(
              '${index + 1}',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          title: Text(entry['name'] ?? 'Anonymous'),
          trailing: Text(
            '${entry['totalSteps']} steps',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        );
      },
    );
  }
}
