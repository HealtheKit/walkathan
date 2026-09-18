import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../repositories/auth_repository_provider.dart';
import '../../../utils/error_dialog.dart';
import '../../../models/custom_error.dart';
import './pedometer_provider.dart';
import '../home/home_provider.dart';
import 'package:go_router/go_router.dart';

class WalkHomePage extends ConsumerStatefulWidget {
  final String userId;

  const WalkHomePage({required this.userId, Key? key}) : super(key: key);

  @override
  _WalkHomePageState createState() => _WalkHomePageState();
}

class _WalkHomePageState extends ConsumerState<WalkHomePage> {
  late final PedometerManager _pedometerManager;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(walkStepRepositoryProvider);
    _pedometerManager = PedometerManager(
      userId: widget.userId,
      walkStepRepository: repo,
    );
    _pedometerManager.stateNotifier.addListener(_onStateChanged);
    _pedometerManager.init();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pedometerManager.stateNotifier.removeListener(_onStateChanged);
    _pedometerManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pedometerState = _pedometerManager.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Walkathan Home'),
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
            image: AssetImage('assets/images/walkbg.png'),
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
        child: Align(
          alignment: FractionalOffset.center,
          child: Container(
            padding: EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Text(
                          'Steps Taken',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          pedometerState.count.toString(),
                          style: TextStyle(fontSize: 48, color: Colors.blue),
                        ),
                        Text(
                          pedometerState.lastUpdate != null
                              ? 'Last updated: ${DateFormat('HH:mm').format(pedometerState.lastUpdate!)}'
                              : 'No updates yet',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 20),
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Text(
                          'Pedestrian Status',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 10),
                        Icon(
                          pedometerState.status == 'walking'
                              ? Icons.directions_walk
                              : pedometerState.status == 'stopped'
                                  ? Icons.accessibility_new
                                  : Icons.error,
                          size: 80,
                          color: pedometerState.status == 'walking'
                              ? Colors.green
                              : pedometerState.status == 'stopped'
                                  ? Colors.blue
                                  : Colors.red,
                        ),
                        Text(
                          pedometerState.status,
                          style: TextStyle(
                            fontSize: 20,
                            color: pedometerState.status == 'walking' || pedometerState.status == 'stopped'
                                ? Colors.black
                                : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                OutlinedButton(
                  onPressed: () {
                    GoRouter.of(context).go('/home');
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white, width: 2),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(
                    'Home',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(height: 40),
                OutlinedButton(
                  onPressed: () {
                    GoRouter.of(context).go('/leaderBoard');
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white, width: 2),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(
                    'Leader Board',
                    style: TextStyle(fontSize: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}