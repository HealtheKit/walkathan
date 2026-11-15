import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/walk_workout/domain/walk_math.dart';
import 'package:walkathan/features/walk_workout/domain/walk_models.dart';

void main() {
  const pace = PaceCalculationService();
  const cal = CalorieCalculationService();

  group('pace', () {
    test('seconds per km and per mile', () {
      expect(pace.paceSeconds(UnitSystem.metric, 1000 / 600), 600); // 10:00 /km
      expect(pace.paceSeconds(UnitSystem.imperial, 1609.344 / 900), 900); // 15:00 /mi
      expect(pace.paceSeconds(UnitSystem.metric, 0.05), isNull, reason: 'not enough movement');
    });
    test('formatting', () {
      expect(pace.formatPace(600), '10:00');
      expect(pace.formatPace(545), '9:05');
      expect(pace.formatPace(null), '--');
    });
    test('average speed needs a little data first', () {
      expect(pace.averageSpeed(840, const Duration(minutes: 10)), closeTo(1.4, 0.001));
      expect(pace.averageSpeed(2, const Duration(seconds: 2)), 0);
    });
    test('unit conversion', () {
      expect(pace.distanceIn(UnitSystem.metric, 2500), 2.5);
      expect(pace.distanceIn(UnitSystem.imperial, 1609.344), closeTo(1, 1e-9));
      expect(pace.speedIn(UnitSystem.metric, 1.5), closeTo(5.4, 1e-9));
    });
  });

  group('distance', () {
    test('haversine', () {
      expect(haversineM(0, 0, 0, 0), 0);
      expect(haversineM(0, 0, 100 / 111320, 0), closeTo(100, 0.5));
    });
  });

  group('calories', () {
    test('brisk walking for an hour at 70 kg is roughly 230 kcal', () {
      final k = cal.kcal(mps: 1.5, weightKg: 70, dt: const Duration(hours: 1)); // 5.4 km/h
      expect(k, closeTo(175, 60));
    });
    test('heavier and faster burn more; standing burns almost nothing', () {
      const h = Duration(minutes: 30);
      expect(cal.kcal(mps: 1.5, weightKg: 90, dt: h), greaterThan(cal.kcal(mps: 1.5, weightKg: 60, dt: h)));
      expect(cal.kcal(mps: 1.9, weightKg: 70, dt: h), greaterThan(cal.kcal(mps: 1.1, weightKg: 70, dt: h)));
      expect(cal.kcal(mps: 0, weightKg: 70, dt: h), lessThan(15));
    });
  });

  group('duration', () {
    test('formats', () {
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)), '01:02:03');
      expect(formatDuration(Duration.zero), '00:00:00');
      expect(formatCompact(const Duration(minutes: 12, seconds: 36)), '12:36');
      expect(formatCompact(const Duration(hours: 1, minutes: 5, seconds: 9)), '1:05:09');
    });
    test('active time is derived from timestamps', () {
      final t0 = DateTime(2026, 1, 1, 9);
      final s = WalkSession(
          id: 'x',
          status: WalkSessionStatus.tracking,
          startedAt: t0,
          settings: const WorkoutSettings(),
          goal: const WorkoutGoal(),
          activeMs: 60000,
          lastResumeAt: t0.add(const Duration(minutes: 5)));
      expect(s.activeDuration(t0.add(const Duration(minutes: 7))).inSeconds, 180);
    });
  });

  group('auto-pause', () {
    test('pauses after standing still long enough, not for a brief stop', () {
      final d = AutoPauseDetector();
      const s = Duration(seconds: 1);
      for (var i = 0; i < 9; i++) {
        expect(d.shouldPause(0, s), isFalse);
      }
      expect(d.shouldPause(1.4, s), isFalse, reason: 'moving again resets the wait');
      for (var i = 0; i < 9; i++) {
        expect(d.shouldPause(0.1, s), isFalse);
      }
      expect(d.shouldPause(0.1, s), isTrue);
    });
    test('resumes after a few seconds of real movement', () {
      final d = AutoPauseDetector();
      const s = Duration(seconds: 1);
      expect(d.shouldResume(1.4, s), isFalse);
      expect(d.shouldResume(0.2, s), isFalse, reason: 'a twitch is not walking');
      expect(d.shouldResume(1.4, s), isFalse);
      expect(d.shouldResume(1.4, s), isFalse);
      expect(d.shouldResume(1.4, s), isTrue);
    });
  });

  group('heart-rate zones', () {
    test('by share of maximum', () {
      expect(heartRateZone(80, 180), 0);
      expect(heartRateZone(100, 180), 1);
      expect(heartRateZone(120, 180), 2);
      expect(heartRateZone(140, 180), 3);
      expect(heartRateZone(170, 180), 4);
    });
  });

  group('summary', () {
    test('averages come from the recorded totals', () {
      final t0 = DateTime(2026, 1, 1, 9);
      final s = WalkSession(
        id: 'x',
        status: WalkSessionStatus.awaitingSave,
        startedAt: t0,
        endedAt: t0.add(const Duration(minutes: 40)),
        settings: const WorkoutSettings(),
        goal: const WorkoutGoal(type: GoalType.distance, target: 2000),
        goalReached: true,
        activeMs: 30 * 60000,
        pausedMs: 10 * 60000,
        distanceM: 2700,
        steps: 3600,
        splits: const [Split(index: 1, durationMs: 680000), Split(index: 2, durationMs: 640000)],
      );
      final sum = WorkoutSummary.of(s, t0.add(const Duration(days: 1)));
      expect(sum.active.inMinutes, 30);
      expect(sum.paused.inMinutes, 10);
      expect(sum.total.inMinutes, 40);
      expect(sum.avgSpeed, closeTo(1.5, 1e-9));
      expect(sum.avgCadence, 120);
      expect(sum.bestSplitMs, 640000);
      expect(sum.goalMet, isTrue);
    });
  });

  group('storage', () {
    test('thin keeps long walks bounded and the newest points intact', () {
      final l = thin(List.generate(4000, (i) => i), 3000);
      expect(l.length, lessThan(3000));
      expect(l.last, 3999);
      expect(l.sublist(l.length - 100), List.generate(100, (i) => 3900 + i));
      expect(thin([1, 2, 3], 10), [1, 2, 3]);
    });
    test('GPX export contains every point', () {
      final s = WalkSession(
        id: 'x',
        status: WalkSessionStatus.completed,
        startedAt: DateTime(2026),
        settings: const WorkoutSettings(),
        goal: const WorkoutGoal(),
        title: 'A & B',
        route: const [
          LocationPoint(lat: 1, lon: 2, tMs: 0, altitude: 5),
          LocationPoint(lat: 1.1, lon: 2.1, tMs: 1000),
        ],
      );
      final gpx = toGpx(s);
      expect('<trkpt'.allMatches(gpx).length, 2);
      expect(gpx, contains('A &amp; B'));
      expect(gpx, contains('<ele>5.0</ele>'));
    });
  });
}
