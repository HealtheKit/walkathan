import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:walkathan/repositories/walk_step_repository.dart';
import 'dart:async';
import 'package:intl/intl.dart';

final walkStepRepositoryProvider = Provider<WalkStepRepository>((ref) => WalkStepRepository());

class PedometerState {
  final String steps;
  final int count;
  final String status;
  final DateTime? lastUpdate;

  PedometerState({this.steps = '0', this.count = 0, this.status = '?', this.lastUpdate});

  PedometerState copyWith({String? steps, int? count, String? status, DateTime? lastUpdate}) {
    return PedometerState(
      steps: steps ?? this.steps,
      count: count ?? this.count,
      status: status ?? this.status,
      lastUpdate: lastUpdate ?? this.lastUpdate,
    );
  }
}

class PedometerManager {
  final String userId;
  final WalkStepRepository walkStepRepository;
  final ValueNotifier<PedometerState> stateNotifier;

  PedometerManager({
    required this.userId,
    required this.walkStepRepository,
  }) : stateNotifier = ValueNotifier(PedometerState());

  PedometerState get state => stateNotifier.value;
  set state(PedometerState newState) => stateNotifier.value = newState;

  Future<void> init() async {
    try {
      await fetchInitialState();
    } catch (e) {
      debugPrint('Error fetching initial state: $e');
    }
    try {
      await initPlatformState();
    } catch (e) {
      debugPrint('Error initializing pedometer: $e');
      state = state.copyWith(
        steps: 'Step Count not available',
        status: 'Pedometer not available on this device',
      );
    }
  }

  Future<void> fetchInitialState() async {
    final initialSteps = await walkStepRepository.getInitialStepCount(userId);
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);

    final lastDay = await walkStepRepository.getLastDay(userId) ?? '';
    if (lastDay != today) {
      await walkStepRepository.saveLastDay(userId, today);
      state = state.copyWith(steps: initialSteps.toString(), count: 0);
    } else {
      final count = await walkStepRepository.getLastCount(userId) ?? 0;
      state = state.copyWith(steps: initialSteps.toString(), count: count);
    }
  }

  Future<void> initPlatformState() async {
    bool granted = await _checkActivityRecognitionPermission();
    if (!granted) {
      state = PedometerState(steps: 'Step Count not available', status: 'Permission Denied', count: state.count);
      return;
    }

    // Use runZonedGuarded to catch PlatformExceptions thrown by the
    // pedometer EventChannel on devices without a step sensor.
    runZonedGuarded(() {
      Pedometer.pedestrianStatusStream.listen(
        onPedestrianStatusChanged,
        onError: onPedestrianStatusError,
        cancelOnError: false,
      );

      Pedometer.stepCountStream.listen(
        onStepCount,
        onError: onStepCountError,
        cancelOnError: false,
      );
    }, (error, stackTrace) {
      debugPrint('Pedometer zone error: $error');
      if (error is PlatformException) {
        state = state.copyWith(
          steps: 'Step Count not available',
          status: 'Pedometer not available on this device',
        );
      }
    });
  }

  Future<bool> _checkActivityRecognitionPermission() async {
    var status = await Permission.activityRecognition.status;
    if (!status.isGranted) {
      status = await Permission.activityRecognition.request();
    }
    return status.isGranted;
  }

  void onStepCount(StepCount event) {
    int newCount = state.count + 1;
    walkStepRepository.saveStepCount(userId, event.steps, newCount);
    state = state.copyWith(
      steps: event.steps.toString(),
      count: newCount,
      lastUpdate: DateTime.now(),
    );
  }

  void onPedestrianStatusChanged(PedestrianStatus event) {
    state = state.copyWith(status: event.status);
  }

  void onPedestrianStatusError(error) {
    state = state.copyWith(status: 'Pedestrian Status not available');
  }

  void onStepCountError(error) {
    state = state.copyWith(steps: 'Step Count not available');
  }

  void dispose() {
    stateNotifier.dispose();
  }
}