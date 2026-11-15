import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/walk_workout/application/walk_session_controller.dart';
import 'package:walkathan/features/walk_workout/data/mock_services.dart';
import 'package:walkathan/features/walk_workout/domain/walk_models.dart';

import 'walk_test_support.dart';

void main() {
  group('starting', () {
    test('counts down 3-2-1 and then tracks', () async {
      final h = WalkHarness();
      await h.c.ready;
      expect(h.s, isNull);
      expect(h.c.start(settings: const WorkoutSettings(), goal: const WorkoutGoal()), StartResult.started);
      expect(h.s!.status, WalkSessionStatus.countingDown);
      expect(h.s!.countdown, 3);
      h.run(1);
      expect(h.s!.countdown, 2);
      h.run(1);
      expect(h.s!.countdown, 1);
      h.run(1);
      await Future<void>.delayed(Duration.zero);
      expect(h.s!.status, WalkSessionStatus.tracking);
      expect(h.tracker.starts, 1);
      expect(h.voice.spoken, contains('Walk started.'));
    });

    test('skip countdown starts at once; the clock starts at the start, not before', () async {
      final h = WalkHarness();
      await h.c.ready;
      h.c.start(settings: const WorkoutSettings(), goal: const WorkoutGoal());
      h.run(2);
      h.c.skipCountdown();
      await Future<void>.delayed(Duration.zero);
      expect(h.s!.status, WalkSessionStatus.tracking);
      expect(h.s!.activeDuration(h.now), Duration.zero);
    });

    test('a second walk cannot start while one is live', () async {
      final h = WalkHarness();
      await h.startWalk();
      final id = h.s!.id;
      for (final act in [() {}, h.c.pause]) {
        act();
        expect(h.c.start(settings: const WorkoutSettings(), goal: const WorkoutGoal()),
            StartResult.alreadyActive);
        expect(h.s!.id, id, reason: 'the running walk is untouched');
      }
      await h.c.finish();
      expect(h.c.start(settings: const WorkoutSettings(), goal: const WorkoutGoal()),
          StartResult.alreadyActive,
          reason: 'still blocked while awaiting save');
      await h.c.discard();
      expect(h.c.start(settings: const WorkoutSettings(), goal: const WorkoutGoal()), StartResult.started);
    });
  });

  group('tracking', () {
    test('accumulates time, distance, steps, calories, pace and heart rate', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(600); // ten minutes at 1.4 m/s
      final s = h.s!;
      expect(s.activeDuration(h.now).inSeconds, 600);
      expect(s.distanceM, closeTo(840, 5));
      expect(s.steps, closeTo(1200, 3));
      expect(s.kcal, greaterThan(20));
      expect(s.kcal, lessThan(40));
      expect(s.currentSpeed, closeTo(1.4, 0.05));
      expect(s.cadence, closeTo(120, 3));
      expect(s.avgHr, 110);
      expect(s.route.length, 600);
      expect(s.series, isNotEmpty);
      expect(s.zoneMs.fold<int>(0, (a, b) => a + b), 600000);
    });

    test('kilometre splits are recorded as they are passed', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.tracker.speed = 2.0;
      h.run(1100); // 2.2 km
      expect(h.s!.splits.length, 2);
      expect(h.s!.splits.first.durationMs, closeTo(500000, 2000));
    });

    test('elevation gain and loss follow the altitude', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.tracker.altitudeSlope = 0.5; // steep climb so each second is above the noise floor
      h.run(60);
      expect(h.s!.elevGain, closeTo(41, 3));
      expect(h.s!.elevLoss, 0);
    });

    test('without GPS distance comes from steps and stride', () async {
      final h = WalkHarness();
      h.tracker.gps = false;
      await h.startWalk(settings: const WorkoutSettings(useGps: false, autoPause: false));
      h.run(100);
      // 200 steps x (170 cm x 0.414)
      expect(h.s!.distanceM, closeTo(200 * 0.7038, 2));
      expect(h.s!.route, isEmpty);
      expect(h.s!.status, WalkSessionStatus.tracking, reason: 'no GPS warning when GPS is off by choice');
    });

    test('losing GPS warns but does not stop the walk', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(20);
      h.tracker.gps = false;
      h.run(8);
      expect(h.s!.status, WalkSessionStatus.gpsWeak);
      final before = h.s!.distanceM;
      h.run(10);
      expect(h.s!.distanceM, greaterThan(before), reason: 'steps keep the distance moving');
      h.tracker.gps = true;
      h.run(2);
      expect(h.s!.status, WalkSessionStatus.tracking);
    });

    test('a long background gap adds at most 30 s of movement per tick', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(10);
      final d0 = h.s!.distanceM;
      h.now = h.now.add(const Duration(minutes: 10));
      h.c.tick();
      expect(h.s!.distanceM - d0, lessThan(1.4 * 31));
      expect(h.s!.activeDuration(h.now).inSeconds, 610, reason: 'time itself comes from timestamps');
    });
  });

  group('pause and resume', () {
    test('pause freezes the metrics and tracks paused time; resume continues', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(60);
      h.c.pause();
      final frozen = h.s!;
      expect(frozen.status, WalkSessionStatus.paused);
      h.run(120);
      expect(h.s!.distanceM, frozen.distanceM);
      expect(h.s!.steps, frozen.steps);
      expect(h.s!.activeDuration(h.now).inSeconds, 60);
      expect(h.s!.pausedDuration(h.now).inSeconds, 120);
      h.c.resume();
      h.run(30);
      expect(h.s!.status, WalkSessionStatus.tracking);
      expect(h.s!.activeDuration(h.now).inSeconds, 90);
      expect(h.s!.pausedDuration(h.now).inSeconds, 120);
      expect(h.s!.totalDuration(h.now).inSeconds, 210);
    });

    test('auto-pause when movement stops, auto-resume when it returns', () async {
      final h = WalkHarness();
      await h.startWalk();
      h.run(30);
      h.tracker.speed = 0;
      h.run(12);
      expect(h.s!.status, WalkSessionStatus.autoPaused);
      expect(h.s!.autoPauseReason, 'Auto-paused because movement stopped');
      final active = h.s!.activeDuration(h.now);
      h.run(20);
      expect(h.s!.activeDuration(h.now), active, reason: 'standing time is not active time');
      h.tracker.speed = 1.4;
      h.run(5);
      expect(h.s!.status, WalkSessionStatus.tracking);
      expect(h.voice.spoken, containsAll(['Auto-paused.', 'Resuming.']));
    });

    test('auto-pause is off when the setting is off', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.tracker.speed = 0;
      h.run(60);
      expect(h.s!.status, WalkSessionStatus.tracking);
    });
  });

  group('laps, goals, coaching', () {
    test('laps record their own time, distance and calories', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(100);
      h.c.addLap();
      h.run(50);
      h.c.addLap();
      final laps = h.s!.laps;
      expect(laps.length, 2);
      expect(laps[0].durationMs, 100000);
      expect(laps[1].durationMs, 50000);
      expect(laps[0].distanceM, closeTo(140, 2));
      expect(laps[1].distanceM, closeTo(70, 2));
      expect(laps[1].kcal, greaterThan(0));
    });

    test('a distance goal is reached once and announced', () async {
      final h = WalkHarness();
      await h.startWalk(
          settings: const WorkoutSettings(autoPause: false),
          goal: const WorkoutGoal(type: GoalType.distance, target: 280));
      h.run(100);
      expect(h.s!.goalReached, isFalse);
      expect(h.s!.goalProgress(h.now), closeTo(0.5, 0.02));
      h.run(110);
      expect(h.s!.goalReached, isTrue);
      expect(h.notifications.milestones, ['Goal reached']);
      h.run(60);
      expect(h.notifications.milestones.length, 1, reason: 'announced once; walking can continue');
      expect(h.s!.status, WalkSessionStatus.tracking);
    });

    test('time and step goals', () async {
      final h = WalkHarness();
      await h.startWalk(
          settings: const WorkoutSettings(autoPause: false),
          goal: const WorkoutGoal(type: GoalType.time, target: 60));
      h.run(61);
      expect(h.s!.goalReached, isTrue);

      final h2 = WalkHarness();
      await h2.startWalk(
          settings: const WorkoutSettings(autoPause: false),
          goal: const WorkoutGoal(type: GoalType.steps, target: 100));
      h2.run(51);
      expect(h2.s!.goalReached, isTrue);
    });

    test('voice announces each kilometre; silent when coaching is off', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.tracker.speed = 2.5;
      h.run(420); // 1.05 km
      expect(h.voice.spoken.where((t) => t.startsWith('1 kilometre')), hasLength(1));

      final quiet = WalkHarness();
      await quiet.startWalk(settings: const WorkoutSettings(autoPause: false, voiceCoaching: false));
      quiet.tracker.speed = 2.5;
      quiet.run(420);
      expect(quiet.voice.spoken, isEmpty);
    });

    test('changing units mid-walk does not change what was recorded', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(120);
      final d = h.s!.distanceM;
      h.c.setUnits(UnitSystem.imperial);
      expect(h.s!.distanceM, d);
      expect(h.s!.settings.units, UnitSystem.imperial);
      h.run(60);
      expect(h.s!.distanceM, closeTo(d + 84, 2));
    });
  });

  group('finish, save, discard', () {
    test('finish stops the sensors and waits for save or discard', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(90);
      await h.c.finish();
      expect(h.s!.status, WalkSessionStatus.awaitingSave);
      expect(h.tracker.stops, 1);
      expect(h.s!.status.isLive, isTrue, reason: 'the banner stays until saved or discarded');
      final at = h.s!.activeDuration(h.now);
      h.now = h.now.add(const Duration(hours: 1));
      expect(h.s!.activeDuration(h.now), at, reason: 'a finished walk no longer runs');
      expect(h.notifications.ongoingTitle, isNull);
    });

    test('save keeps the walk in history and clears the session', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(90);
      await h.c.finish();
      await h.c.save(title: 'Morning walk', note: 'felt good');
      expect(h.s, isNull);
      expect(h.store.active, isNull);
      expect(h.store.workouts.single.session.title, 'Morning walk');
      expect(h.store.workouts.single.session.note, 'felt good');
      expect(h.store.workouts.single.session.status, WalkSessionStatus.completed);
      expect(h.container.read(walkIsLiveProvider), isFalse);
    });

    test('discard removes everything', () async {
      final h = WalkHarness();
      await h.startWalk();
      h.run(30);
      await h.c.discard();
      expect(h.s, isNull);
      expect(h.store.active, isNull);
      expect(h.store.workouts, isEmpty);
      expect(h.tracker.stops, 1);
    });

    test('the notification mirrors the in-app status', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      h.run(10);
      expect(h.notifications.ongoingTitle, 'Walk in progress');
      h.c.pause();
      expect(h.notifications.ongoingTitle, 'Walk paused');
      h.c.resume();
      expect(h.notifications.ongoingTitle, 'Walk in progress');
    });
  });

  group('recovery after the app is closed', () {
    test('a paused walk comes back paused with every number intact', () async {
      final store = MemoryWorkoutPersistence();
      final a = WalkHarness(store: store);
      await a.startWalk(
          settings: const WorkoutSettings(autoPause: false),
          goal: const WorkoutGoal(type: GoalType.distance, target: 5000));
      a.run(300);
      a.c.addLap();
      a.c.pause();
      final before = a.s!;

      // app killed; started again an hour later
      final b = WalkHarness(store: store, start: a.now.add(const Duration(hours: 1)));
      await b.c.ready;
      final s = b.s!;
      expect(s.id, before.id);
      expect(s.status, WalkSessionStatus.paused);
      expect(s.distanceM, closeTo(before.distanceM, 0.01));
      expect(s.steps, before.steps);
      expect(s.kcal, closeTo(before.kcal, 0.01));
      expect(s.laps.length, 1);
      expect(s.route.length, before.route.length);
      expect(s.goal.type, GoalType.distance);
      expect(s.activeDuration(b.now).inSeconds, 300);
      expect(s.recovered, isTrue);

      b.c.resume();
      expect(b.tracker.starts, 1, reason: 'sensors restart for a restored walk');
      b.run(60);
      expect(b.s!.activeDuration(b.now).inSeconds, 360);
      expect(b.s!.distanceM, greaterThan(before.distanceM + 70));
    });

    test('a walk that was tracking and reopened quickly keeps going', () async {
      final store = MemoryWorkoutPersistence();
      final a = WalkHarness(store: store);
      await a.startWalk(settings: const WorkoutSettings(autoPause: false));
      a.run(60);
      final b = WalkHarness(store: store, start: a.now.add(const Duration(seconds: 30)));
      await b.c.ready;
      expect(b.s!.status, WalkSessionStatus.tracking);
      expect(b.s!.activeDuration(b.now).inSeconds, closeTo(90, 1));
      expect(b.tracker.starts, 1);
    });

    test('a walk that was tracking and reopened hours later is not invented', () async {
      final store = MemoryWorkoutPersistence();
      final a = WalkHarness(store: store);
      await a.startWalk(settings: const WorkoutSettings(autoPause: false));
      a.run(60);
      final b = WalkHarness(store: store, start: a.now.add(const Duration(hours: 5)));
      await b.c.ready;
      expect(b.s!.status, WalkSessionStatus.autoPaused);
      expect(b.s!.autoPauseReason, 'Paused because the app was closed');
      expect(b.s!.activeDuration(b.now).inSeconds, lessThanOrEqualTo(60));
      b.run(30);
      expect(b.s!.status, WalkSessionStatus.autoPaused, reason: 'it waits for the walker');
    });

    test('a finished, unsaved walk comes back at "save or discard"', () async {
      final store = MemoryWorkoutPersistence();
      final a = WalkHarness(store: store);
      await a.startWalk(settings: const WorkoutSettings(autoPause: false));
      a.run(120);
      await a.c.finish();
      final b = WalkHarness(store: store, start: a.now.add(const Duration(days: 1)));
      await b.c.ready;
      expect(b.s!.status, WalkSessionStatus.awaitingSave);
      expect(b.s!.activeDuration(b.now).inSeconds, 120);
      expect(b.c.start(settings: const WorkoutSettings(), goal: const WorkoutGoal()),
          StartResult.alreadyActive);
    });

    test('a walk still in its countdown is not restored', () async {
      final store = MemoryWorkoutPersistence();
      final a = WalkHarness(store: store);
      await a.c.ready;
      a.c.start(settings: const WorkoutSettings(), goal: const WorkoutGoal());
      await Future<void>.delayed(Duration.zero);
      final b = WalkHarness(store: store, start: a.now.add(const Duration(minutes: 1)));
      await b.c.ready;
      expect(b.s, isNull);
      expect(store.active, isNull);
    });

    test('the session is written to storage while walking, not only at the end', () async {
      final h = WalkHarness();
      await h.startWalk(settings: const WorkoutSettings(autoPause: false));
      final writes = h.store.activeWrites;
      h.run(31);
      expect(h.store.activeWrites - writes, greaterThanOrEqualTo(5));
      expect(h.store.active!.distanceM, greaterThan(30));
    });
  });
}
