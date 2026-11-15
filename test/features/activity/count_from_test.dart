import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkathan/core/time/local_day.dart';
import 'package:walkathan/features/activity/count_from.dart';
import 'package:walkathan/features/activity/movement_ledger.dart';
import 'package:walkathan/features/activity/sensor_step_source.dart';
import 'package:walkathan/features/activity/step_day.dart';

void main() {
  final day = DateTime(2026, 11, 15);
  final end = DateTime(2026, 11, 16);

  group('cutInside', () {
    test('no reset: count the whole day', () {
      expect(cutInside(day, end, null), isNull);
    });
    test('reset during the day: count from the reset', () {
      final at = DateTime(2026, 11, 15, 10, 20);
      expect(cutInside(day, end, at), at);
    });
    test('reset on a later day: this day is history, left alone', () {
      expect(cutInside(day, end, DateTime(2026, 11, 16, 9)), isNull);
    });
    test('reset on an earlier day: this day counts in full', () {
      expect(cutInside(day, end, DateTime(2026, 11, 14, 9)), isNull);
    });
    test('today, cut off at "now"', () {
      final now = DateTime(2026, 11, 15, 12);
      expect(cutInside(day, now, DateTime(2026, 11, 15, 11)), isNotNull);
    });
  });

  group('SensorCut', () {
    final cf = DateTime(2026, 11, 15, 10, 20);
    List<int> hours(Map<int, int> m) => [for (var h = 0; h < 24; h++) m[h] ?? 0];

    test('everything up to the reset hour is removed, later hours count', () {
      final cut = SensorCut.snapshot(cf, '2026-11-15', hours({8: 3000, 10: 555}));
      expect(cut.apply(hours({8: 3000, 10: 555})).fold<int>(0, (a, b) => a + b), 0,
          reason: 'zero right after the reset');
      final later = cut.apply(hours({8: 3000, 10: 600, 11: 400}));
      expect(later[8], 0);
      expect(later[10], 45, reason: 'steps in the reset hour after the reset');
      expect(later[11], 400);
    });

    test('survives a restart and never goes negative', () {
      final cut = SensorCut.decode(SensorCut.snapshot(cf, '2026-11-15', hours({9: 100})).encode())!;
      expect(cut.date, '2026-11-15');
      expect(cut.countFrom.isAtSameMomentAs(cf), isTrue);
      expect(cut.apply(hours({9: 40})).every((v) => v >= 0), isTrue);
      expect(SensorCut.decode('nonsense'), isNull);
      expect(SensorCut.decode(null), isNull);
    });
  });

  group('StepDay with a reset', () {
    StepDay d(int steps, {DateTime? from, StepSourceKind src = StepSourceKind.phoneSensor, int obs = 0}) =>
        StepDay(
            localDate: '2026-11-15',
            offsetMin: 0,
            source: src,
            steps: steps,
            countedFrom: from,
            observedAt: DateTime.utc(2026, 11, 15, 12, obs));
    final cf = DateTime.utc(2026, 11, 15, 10);

    test('a freshly cut sensor total replaces a larger old one', () {
      expect(d(5000).merge(d(0, from: cf)).steps, 0);
      expect(d(0, from: cf).merge(d(5000)).steps, 0, reason: 'order does not matter');
      expect(d(0, from: cf).merge(d(40, from: cf)).steps, 40, reason: 'then it grows as usual');
    });

    test('resolveDay shows the fresh total', () {
      expect(resolveDay([d(5000), d(30, from: cf)])!.steps, 30);
    });

    test('the reset travels to the server and back', () {
      final j = d(12, from: cf).toJson();
      expect(j['counted_from'], isNotNull);
      expect(StepDay.fromJson(j).countedFrom!.isAtSameMomentAs(cf), isTrue);
      expect(d(12).toJson().containsKey('counted_from'), isFalse);
    });
  });

  group('SensorStepSource', () {
    test('after a reset the day restarts from zero and stays cut', () async {
      SharedPreferences.setMockInitialValues({});
      var counter = 1000;
      final now = DateTime.now();
      DateTime? cf;
      final src = SensorStepSource(
        profileId: 'p1',
        readCounter: () async => counter,
        loadMovement: () async => MovementLedger(),
        countFrom: () async => cf,
      );
      Future<int> today(DateTime at) async {
        final r = await src.readDays([at], now: at);
        return r.isEmpty ? -1 : r.first.steps;
      }

      await today(now); // baseline
      counter = 1555;
      expect(await today(now.add(const Duration(seconds: 30))), 555);

      // the organizer sets this profile to zero
      cf = now.add(const Duration(seconds: 40));
      final first = await src.readDays([now], now: now.add(const Duration(seconds: 50)));
      expect(first.single.steps, 0, reason: 'old steps are gone');
      expect(first.single.countedFrom, isNotNull);

      // new steps count; the old 555 never come back
      counter = 1600;
      final t = now.add(const Duration(seconds: 90));
      if (dateKey(t) == dateKey(now) && t.hour == now.hour) {
        expect(await today(t), 45);
      }

      // undo: the full day is back
      cf = null;
      final after = await today(now.add(const Duration(seconds: 120)));
      if (dateKey(t) == dateKey(now)) expect(after, 600);
    });
  });
}
