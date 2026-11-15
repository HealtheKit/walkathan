import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkathan/features/activity/step_day.dart';
import 'package:walkathan/features/activity/step_queue.dart';

StepDay day(String date, int steps,
        {StepSourceKind src = StepSourceKind.healthStore}) =>
    StepDay(localDate: date, offsetMin: 180, source: src, steps: steps);

void main() {
  group('resolveDay', () {
    test('health store beats a HIGHER raw sensor total (sensor cannot see '
        'bike sessions)', () {
      final r = resolveDay([
        day('2026-11-13', 4000),
        day('2026-11-13', 9000, src: StepSourceKind.phoneSensor),
      ]);
      expect(r!.steps, 4000);
      expect(r.source, StepSourceKind.healthStore);
    });

    test('sensor is used when the health store has nothing', () {
      final r = resolveDay([day('2026-11-13', 3000, src: StepSourceKind.phoneSensor)]);
      expect(r!.source, StepSourceKind.phoneSensor);
      expect(r.steps, 3000);
    });

    test('newest health reading wins even if lower', () {
      final older = StepDay(
          localDate: '2026-11-13', offsetMin: 180, source: StepSourceKind.healthStore,
          steps: 5000, observedAt: DateTime(2026, 11, 13, 9));
      final newer = StepDay(
          localDate: '2026-11-13', offsetMin: 180, source: StepSourceKind.healthStore,
          steps: 1500, observedAt: DateTime(2026, 11, 13, 10));
      expect(resolveDay([older, newer])!.steps, 1500);
      expect(resolveDay([newer, older])!.steps, 1500);
    });

    test('empty gives null', () => expect(resolveDay([]), isNull));
  });

  group('StepDay.merge', () {
    StepDay h(int steps, int hour) => StepDay(
        localDate: '2026-11-13', offsetMin: 180, source: StepSourceKind.healthStore,
        steps: steps, observedAt: DateTime(2026, 11, 13, hour));

    test('health: a newer lower reading corrects downward', () {
      expect(h(5000, 9).merge(h(1500, 10)).steps, 1500);
    });
    test('health: an older reading never overwrites a newer one', () {
      expect(h(1500, 10).merge(h(5000, 9)).steps, 1500);
    });
    test('sensor: the larger total wins and never goes down', () {
      final a = day('2026-11-13', 3000, src: StepSourceKind.phoneSensor);
      final b = day('2026-11-13', 2000, src: StepSourceKind.phoneSensor);
      expect(a.merge(b).steps, 3000);
      expect(b.merge(a).steps, 3000);
    });
  });

  test('toJson/fromJson round-trip and omit missing metrics', () {
    final d = StepDay(
        localDate: '2026-11-13', offsetMin: 180,
        source: StepSourceKind.healthStore, steps: 100, kcal: 5);
    final json = d.toJson();
    expect(json.containsKey('distance_m'), isFalse);
    expect(json.containsKey('excluded_steps'), isFalse,
        reason: 'display-only; never uploaded');
    expect(json['observed_at'], isA<String>());
    expect(json['source'], 'health_store');
    final back = StepDay.fromJson(json);
    expect(back.steps, 100);
    expect(back.kcal, 5);
    expect(back.distanceM, isNull);
  });

  group('StepQueue', () {
    late StepQueue q;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      q = StepQueue(await SharedPreferences.getInstance(), 'profile-1');
    });

    test('sensor entries keep only the largest total', () async {
      StepDay s(int n) => day('2026-11-13', n, src: StepSourceKind.phoneSensor);
      await q.put(s(1000), now: DateTime(2026, 11, 13));
      await q.put(s(4000), now: DateTime(2026, 11, 13));
      await q.put(s(2500), now: DateTime(2026, 11, 13)); // stale
      expect(q.pending().single.steps, 4000);
    });

    test('health entries keep the newest reading (can go down)', () async {
      StepDay h(int n, int hour) => StepDay(
          localDate: '2026-11-13', offsetMin: 180, source: StepSourceKind.healthStore,
          steps: n, observedAt: DateTime(2026, 11, 13, hour));
      await q.put(h(5000, 9), now: DateTime(2026, 11, 13));
      await q.put(h(1500, 10), now: DateTime(2026, 11, 13)); // corrected
      expect(q.pending().single.steps, 1500);
    });

    test('different sources are kept separately', () async {
      await q.put(day('2026-11-13', 1000), now: DateTime(2026, 11, 13));
      await q.put(day('2026-11-13', 900, src: StepSourceKind.phoneSensor),
          now: DateTime(2026, 11, 13));
      expect(q.pendingCount, 2);
    });

    test('drops entries older than 31 days', () async {
      await q.put(day('2026-09-01', 5000), now: DateTime(2026, 11, 13));
      await q.put(day('2026-11-12', 5000), now: DateTime(2026, 11, 13));
      expect(q.pending().map((d) => d.localDate), ['2026-11-12']);
    });

    test('remove clears handled entries only', () async {
      await q.put(day('2026-11-12', 1), now: DateTime(2026, 11, 13));
      await q.put(day('2026-11-13', 2), now: DateTime(2026, 11, 13));
      await q.remove(['2026-11-12|health_store']);
      expect(q.pending().single.localDate, '2026-11-13');
    });

    test('queues are separate per profile', () async {
      final prefs = await SharedPreferences.getInstance();
      final other = StepQueue(prefs, 'profile-2');
      await q.put(day('2026-11-13', 10), now: DateTime(2026, 11, 13));
      expect(other.pendingCount, 0);
    });

    test('corrupt stored data is ignored, not fatal', () async {
      SharedPreferences.setMockInitialValues({'step_queue_profile-1': '{{bad'});
      final bad = StepQueue(await SharedPreferences.getInstance(), 'profile-1');
      expect(bad.pending(), isEmpty);
      await bad.put(day('2026-11-13', 7), now: DateTime(2026, 11, 13));
      expect(bad.pendingCount, 1);
    });
  });
}
