import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:walkathan/features/walk_workout/application/walk_session_controller.dart';
import 'package:walkathan/features/walk_workout/data/mock_services.dart';
import 'package:walkathan/features/walk_workout/domain/walk_models.dart';
import 'package:walkathan/features/walk_workout/domain/walk_services.dart';

/// A tracker the test scripts: walks north at [speed] m/s, [stepsPerSec].
class FakeTracker implements WalkTrackingService {
  double speed = 1.4;
  double stepsPerSec = 2;
  int? heartRate = 110;
  bool gps = true;
  double accuracy = 5;
  double altitudeSlope = 0; // metres of climb per metre walked
  int starts = 0, stops = 0;

  double _north = 0;
  double _stepCarry = 0;
  int _t = 0;

  @override
  Future<void> start(WorkoutSettings settings) async => starts++;
  @override
  Future<void> stop() async => stops++;

  @override
  TrackSample advance(Duration dt) {
    final s = dt.inMilliseconds / 1000;
    _t += dt.inMilliseconds;
    _north += speed * s;
    _stepCarry += stepsPerSec * s;
    final steps = _stepCarry.floor();
    _stepCarry -= steps;
    return TrackSample(
      location: gps
          ? LocationPoint(
              lat: _north / 111320, lon: 0, tMs: _t, altitude: 10 + _north * altitudeSlope, accuracyM: accuracy)
          : null,
      stepsDelta: speed <= 0 ? 0 : steps,
      heartRate: heartRate,
    );
  }
}

/// Everything a walk test needs, with time under the test's control.
class WalkHarness {
  WalkHarness({MemoryWorkoutPersistence? store, DateTime? start})
      : store = store ?? MemoryWorkoutPersistence(),
        now = start ?? DateTime(2026, 11, 15, 9);

  final MemoryWorkoutPersistence store;
  final FakeTracker tracker = FakeTracker();
  final MockVoiceCoachService voice = MockVoiceCoachService();
  final MockNotificationService notifications = MockNotificationService();
  DateTime now;
  late final ProviderContainer container = ProviderContainer(overrides: overrides);

  List<Override> get overrides => [
        walkClockProvider.overrideWithValue(() => now),
        walkAutoTickProvider.overrideWithValue(false),
        walkTrackingServiceProvider.overrideWithValue(tracker),
        workoutPersistenceProvider.overrideWithValue(store),
        voiceCoachProvider.overrideWithValue(voice),
        walkNotificationProvider.overrideWithValue(notifications),
        walkUserProfileProvider.overrideWithValue(const UserProfile(age: 40, heightCm: 170, weightKg: 70)),
      ];

  WalkSessionController get c => container.read(walkSessionProvider.notifier);
  WalkSession? get s => container.read(walkSessionProvider);

  /// Advances time by [seconds], one tick per second.
  void run(int seconds) {
    for (var i = 0; i < seconds; i++) {
      now = now.add(const Duration(seconds: 1));
      c.tick();
    }
  }

  /// Starts a walk and gets past the countdown.
  Future<void> startWalk({
    WorkoutSettings settings = const WorkoutSettings(),
    WorkoutGoal goal = const WorkoutGoal(),
  }) async {
    await c.ready;
    c.start(settings: settings, goal: goal);
    c.skipCountdown();
    await Future<void>.delayed(Duration.zero);
  }
}
