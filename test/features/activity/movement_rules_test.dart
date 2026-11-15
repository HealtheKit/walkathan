import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart' show HealthWorkoutActivityType;
import 'package:walkathan/features/activity/movement_rules.dart';

DateTime t(int h, [int m = 0]) => DateTime(2026, 11, 13, h, m);

void main() {
  final day = TimeSpan(DateTime(2026, 11, 13), DateTime(2026, 11, 14));

  group('which workouts are excluded', () {
    test('indoor and outdoor cycling and exercise machines are excluded', () {
      for (final w in [
        HealthWorkoutActivityType.BIKING,
        HealthWorkoutActivityType.BIKING_STATIONARY,
        HealthWorkoutActivityType.ELLIPTICAL,
        HealthWorkoutActivityType.ROWING_MACHINE,
        HealthWorkoutActivityType.STAIR_CLIMBING_MACHINE,
      ]) {
        expect(kNonLocomotionWorkouts, contains(w), reason: '$w');
      }
    });

    test('treadmill sessions are excluded too (Android types)', () {
      expect(kNonLocomotionWorkouts, contains(HealthWorkoutActivityType.WALKING_TREADMILL));
      expect(kNonLocomotionWorkouts, contains(HealthWorkoutActivityType.RUNNING_TREADMILL));
    });

    test('iOS indoor sessions are excluded via the HKIndoorWorkout flag', () {
      expect(isExcludedWorkout(HealthWorkoutActivityType.RUNNING, {'HKIndoorWorkout': true}), isTrue);
      expect(isExcludedWorkout(HealthWorkoutActivityType.WALKING, {'HKIndoorWorkout': 1}), isTrue);
      expect(isExcludedWorkout(HealthWorkoutActivityType.WALKING, {'HKIndoorWorkout': '1'}), isTrue);
    });

    test('outdoor walking, running and hiking still count', () {
      for (final w in [
        HealthWorkoutActivityType.WALKING,
        HealthWorkoutActivityType.RUNNING,
        HealthWorkoutActivityType.HIKING,
      ]) {
        expect(isExcludedWorkout(w, null), isFalse, reason: '$w');
        expect(isExcludedWorkout(w, {'HKIndoorWorkout': false}), isFalse, reason: '$w');
        expect(isExcludedWorkout(w, {'other': true}), isFalse, reason: '$w');
      }
    });
  });

  group('normalizeSpans', () {
    test('merges overlapping and touching sessions', () {
      final r = normalizeSpans([
        TimeSpan(t(9), t(10)),
        TimeSpan(t(9, 30), t(11)),
        TimeSpan(t(11), t(12)),
        TimeSpan(t(15), t(16)),
      ], day);
      expect(r.length, 2);
      expect(r.first.from, t(9));
      expect(r.first.to, t(12));
    });

    test('clamps to the day and drops empty or outside spans', () {
      final r = normalizeSpans([
        TimeSpan(DateTime(2026, 11, 12, 23), t(1)), // started yesterday
        TimeSpan(t(5), t(5)), // empty
        TimeSpan(DateTime(2026, 11, 14, 1), DateTime(2026, 11, 14, 2)), // tomorrow
      ], day);
      expect(r.length, 1);
      expect(r.single.from, DateTime(2026, 11, 13));
      expect(r.single.to, t(1));
    });
  });

  group('stepsExcludingSessions', () {
    // 100 steps per hour for any interval, to make results easy to reason about.
    Future<int?> perHour(DateTime a, DateTime b) async =>
        (b.difference(a).inMinutes * 100 / 60).round();

    test('subtracts the steps recorded during an excluded session', () async {
      final r = await stepsExcludingSessions(
        total: 5000,
        sessions: [TimeSpan(t(18), t(19, 30))], // 1.5h on an exercise bike
        window: day,
        stepsBetween: perHour,
      );
      expect(r.excluded, 150);
      expect(r.steps, 4850);
    });

    test('overlapping sessions are not subtracted twice', () async {
      final r = await stepsExcludingSessions(
        total: 5000,
        sessions: [TimeSpan(t(9), t(10)), TimeSpan(t(9, 30), t(10, 30))],
        window: day,
        stepsBetween: perHour,
      );
      expect(r.excluded, 150); // 1.5h merged, not 2h
    });

    test('no sessions means nothing is removed', () async {
      final r = await stepsExcludingSessions(
          total: 5000, sessions: const [], window: day, stepsBetween: perHour);
      expect(r.steps, 5000);
      expect(r.excluded, 0);
    });

    test('unknown steps in a session are not guessed or subtracted', () async {
      final r = await stepsExcludingSessions(
        total: 5000,
        sessions: [TimeSpan(t(9), t(10))],
        window: day,
        stepsBetween: (a, b) async => null,
      );
      expect(r.steps, 5000);
    });

    test('never goes below zero', () async {
      final r = await stepsExcludingSessions(
        total: 100,
        sessions: [TimeSpan(t(0), t(23))],
        window: day,
        stepsBetween: (a, b) async => 99999,
      );
      expect(r.steps, 0);
      expect(r.excluded, 100);
    });
  });
}
