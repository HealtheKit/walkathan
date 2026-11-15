import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/activity/sensor_delta_tracker.dart';

void main() {
  gpsTests();
  SensorDeltaTracker fresh() => SensorDeltaTracker(SensorLedger());

  test('first reading only sets a baseline (no invented steps)', () {
    final t = fresh();
    expect(t.addReading(5000, DateTime(2026, 11, 13, 9)), 0);
    expect(t.stepsFor(DateTime(2026, 11, 13)), 0);
  });

  test('later readings add the difference on the same day', () {
    final t = fresh();
    t.addReading(5000, DateTime(2026, 11, 13, 9));
    expect(t.addReading(5300, DateTime(2026, 11, 13, 10)), 300);
    t.addReading(6000, DateTime(2026, 11, 13, 15));
    expect(t.stepsFor(DateTime(2026, 11, 13)), 1000);
  });

  test('a reboot (counter drops) counts the new counter as new steps', () {
    final t = fresh();
    t.addReading(9000, DateTime(2026, 11, 13, 8));
    t.addReading(9500, DateTime(2026, 11, 13, 9));
    // phone restarts; counter is now small
    expect(t.addReading(120, DateTime(2026, 11, 13, 12)), 120);
    expect(t.stepsFor(DateTime(2026, 11, 13)), 500 + 120);
  });

  test('a gap across midnight is split by time between the two days', () {
    final t = fresh();
    t.addReading(1000, DateTime(2026, 11, 13, 22)); // 22:00
    // 4 hours later: 2h on the 13th, 2h on the 14th, 400 steps total
    expect(t.addReading(1400, DateTime(2026, 11, 14, 2)), 400);
    expect(t.stepsFor(DateTime(2026, 11, 13)), 200);
    expect(t.stepsFor(DateTime(2026, 11, 14)), 200);
    // nothing is lost or invented
    expect(t.stepsFor(DateTime(2026, 11, 13)) + t.stepsFor(DateTime(2026, 11, 14)), 400);
  });

  test('a multi-day gap splits across every day and conserves the total', () {
    final t = fresh();
    t.addReading(0, DateTime(2026, 11, 10, 12));
    t.addReading(7001, DateTime(2026, 11, 13, 12)); // 72h later
    var sum = 0;
    for (var d = 10; d <= 13; d++) {
      sum += t.stepsFor(DateTime(2026, 11, d));
    }
    expect(sum, 7001);
    expect(t.stepsFor(DateTime(2026, 11, 11)), greaterThan(2000)); // a full day
  });

  test('clock going backwards ignores the delta but moves the baseline', () {
    final t = fresh();
    t.addReading(1000, DateTime(2026, 11, 13, 10));
    expect(t.addReading(1500, DateTime(2026, 11, 13, 9)), 0);
    expect(t.stepsFor(DateTime(2026, 11, 13)), 0);
    expect(t.addReading(1600, DateTime(2026, 11, 13, 11)), 100);
  });

  test('an identical reading adds nothing', () {
    final t = fresh();
    t.addReading(1000, DateTime(2026, 11, 13, 10));
    expect(t.addReading(1000, DateTime(2026, 11, 13, 11)), 0);
  });

  test('state survives encode/decode, and corrupt state starts clean', () {
    final t = fresh();
    t.addReading(100, DateTime(2026, 11, 13, 8));
    t.addReading(400, DateTime(2026, 11, 13, 9));
    final restored = SensorDeltaTracker(SensorLedger.decode(t.ledger.encode()));
    expect(restored.stepsFor(DateTime(2026, 11, 13)), 300);
    expect(restored.addReading(500, DateTime(2026, 11, 13, 10)), 100);

    expect(SensorLedger.decode('not json{').days, isEmpty);
    expect(SensorLedger.decode(null).lastCounter, isNull);
  });

  test('old days are pruned', () {
    final t = SensorDeltaTracker(SensorLedger(), keepDays: 5);
    t.addReading(0, DateTime(2026, 11, 1, 12));
    t.addReading(100, DateTime(2026, 11, 1, 13));
    t.addReading(200, DateTime(2026, 11, 20, 13));
    expect(t.ledger.days.keys, isNot(contains('2026-11-01')));
  });
}

// ---- GPS: steps while the phone stood still are dropped
void gpsTests() {
  group('stationary share (GPS)', () {
    final t0 = DateTime(2026, 11, 1, 10);

    test('shaking in place adds no steps', () {
      final t = SensorDeltaTracker(SensorLedger());
      t.addReading(1000, t0);
      final n = t.addReading(1300, t0.add(const Duration(minutes: 1)),
          stationaryShare: (a, b) => 1.0);
      expect(n, 0);
      expect(t.stepsFor(t0), 0);
    });

    test('half stationary keeps half; unknown keeps all', () {
      final t = SensorDeltaTracker(SensorLedger());
      t.addReading(0, t0);
      expect(t.addReading(200, t0.add(const Duration(minutes: 1)), stationaryShare: (a, b) => 0.5), 100);
      expect(t.addReading(400, t0.add(const Duration(minutes: 2)), stationaryShare: (a, b) => 0), 200);
      expect(t.addReading(500, t0.add(const Duration(minutes: 3))), 100);
      expect(t.stepsFor(t0), 400);
    });

    test('the baseline still advances so dropped steps never return', () {
      final t = SensorDeltaTracker(SensorLedger());
      t.addReading(0, t0);
      t.addReading(300, t0.add(const Duration(minutes: 1)), stationaryShare: (a, b) => 1.0);
      expect(t.addReading(320, t0.add(const Duration(minutes: 2))), 20);
    });
  });
}
