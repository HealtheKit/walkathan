import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/activity/movement_rules.dart';
import 'package:walkathan/features/activity/sensor_delta_tracker.dart';
import 'package:walkathan/features/events/event_scoring.dart';

List<int> hoursAt(int start, int len, int perHour) =>
    [for (var h = 0; h < 24; h++) h >= start && h < start + len ? perHour : 0];

EventDayRecord rec(int day, int steps, {List<int>? hours, int? dist}) => EventDayRecord(
    date: DateTime(2026, 11, day), steps: steps, hours: hours, distanceM: dist, kcal: steps ~/ 25);

void main() {
  // Event Nov 2 (Mon) .. Nov 15; today Fri Nov 13 (12th day)
  final cfg = EventConfig(
      startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 15), dailyTarget: 5000, rewardMinSteps: 30000, rewardMinActivePct: 50);
  final today = DateTime(2026, 11, 13, 10);

  EventScore score(List<EventDayRecord> days) => EventScore.compute(cfg, days, today);

  test('totals, progress and averages', () {
    final s = score([rec(2, 6000), rec(3, 4000), rec(13, 2000)]);
    expect(s.daysCompleted, 12);
    expect(s.daysRemaining, 2);
    expect(s.eventProgress, closeTo(12 / 14, 1e-9));
    expect(s.totalSteps, 12000);
    expect(s.averageDaily, 1000);
    expect(s.activeDays, 3);
    expect(s.activeDayRate, closeTo(3 / 12, 1e-9));
  });

  test('step consistency: identical days = 100, uneven days lower, none = 0', () {
    final even = score([for (var d = 2; d <= 13; d++) rec(d, 5000)]);
    expect(even.stepConsistency, 100);
    final uneven = score([rec(2, 20000), rec(5, 100)]);
    expect(uneven.stepConsistency, lessThan(20));
    expect(score([]).stepConsistency, 0);
  });

  test('streaks: current (today pending ok), longest, recovery after a gap', () {
    final s = score([for (var d = 2; d <= 8; d++) rec(d, 100), rec(11, 100), rec(12, 100)]);
    expect(s.longestStreak, 7);
    expect(s.currentStreak, 2); // 11, 12; today (13) not yet walked
    expect(s.recoveredAfterMissed, 2); // missed 9 and 10
    expect(score([for (var d = 2; d <= 13; d++) rec(d, 1)]).recoveredAfterMissed, isNull);
    expect(score([rec(13, 50)]).recoveredAfterMissed, isNull, reason: 'first walk is not a recovery');
  });

  test('calendar statuses', () {
    final s = score([rec(2, 6000), rec(3, 3000), rec(4, 1000)]);
    expect(s.statusOf(DateTime(2026, 11, 2)), DayStatus.targetMet);
    expect(s.statusOf(DateTime(2026, 11, 3)), DayStatus.active);
    expect(s.statusOf(DateTime(2026, 11, 4)), DayStatus.low);
    expect(s.statusOf(DateTime(2026, 11, 5)), DayStatus.missed);
    expect(s.statusOf(DateTime(2026, 11, 13)), DayStatus.low, reason: 'today pending, not missed');
    expect(s.statusOf(DateTime(2026, 11, 14)), DayStatus.future);
    expect(s.targetMetDays, 1);
  });

  test('timing: usual window at any hour, consistency share, early mornings', () {
    // walks 6-7 AM on four days, one day at 6 PM
    final s = score([
      rec(2, 3000, hours: hoursAt(6, 1, 3000)),
      rec(3, 3000, hours: hoursAt(6, 1, 3000)),
      rec(4, 3000, hours: hoursAt(7, 1, 3000)),
      rec(5, 3000, hours: hoursAt(6, 2, 1500)),
      rec(6, 3000, hours: hoursAt(18, 1, 3000)),
    ]);
    expect(s.usualStartHour, 6);
    expect(s.timingConsistency, 80); // 4 of 5 within an hour of 6 AM
    expect(s.earlyMorningDays, 4);
    expect(s.longestWalkHours, 2);
    expect(s.averageWalkHours, closeTo(1.2, 1e-9));
    // an evening walker is just as consistent
    final evening = score([for (var d = 2; d <= 6; d++) rec(d, 3000, hours: hoursAt(19, 1, 3000))]);
    expect(evening.timingConsistency, 100);
    expect(evening.earlyMorningDays, 0);
    expect(score([rec(2, 3000)]).timingConsistency, isNull, reason: 'needs 3 timed days');
  });

  test('walk window ignores stray low hours', () {
    final h = List<int>.filled(24, 0)..[3] = 50..[8] = 900..[9] = 400..[22] = 120;
    final w = walkWindow(h)!;
    expect(w.startHour, 8);
    expect(w.endHour, 10);
    expect(walkWindow(null), isNull);
    expect(walkWindow(List<int>.filled(24, 10)), isNull);
  });

  test('weekly comparison, best and worst day, best week', () {
    final s = score([rec(2, 1000), rec(3, 3000), rec(9, 5000), rec(10, 500), rec(12, 9000)]);
    final tw = s.thisWeek; // Nov 9..13 counted (14,15 future)
    expect(tw.total, 14500);
    expect(tw.average, 2900);
    expect(tw.best, DateTime(2026, 11, 12));
    expect(tw.worst, DateTime(2026, 11, 11));
    expect(s.lastWeek.total, 4000);
    expect(s.bestWeekTotal, 14500);
    expect(s.bestDay.steps, 9000);
  });

  test('cumulative trend', () {
    final t = score([rec(2, 100), rec(4, 50)]).trend;
    expect(t.first.cumulative, 100);
    expect(t.last.cumulative, 150);
    expect(t.length, 12);
  });

  test('milestones include the event target; reward eligibility', () {
    final s = score([for (var d = 2; d <= 8; d++) rec(d, 5000)]);
    expect(s.totalSteps, 35000);
    expect(s.milestones.map((m) => m.steps), contains(30000));
    expect(s.milestones.firstWhere((m) => m.steps == 30000).reached, isTrue);
    expect(s.nextMilestone!.steps, 50000);
    expect(s.rewardEligible, isTrue); // 35k >= 30k and 7/14 = 50%
    expect(score([rec(2, 40000)]).rewardEligible, isFalse, reason: 'too few active days');
    final noRule = EventScore.compute(
        EventConfig(startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 15)), [rec(2, 99999)], today);
    expect(noRule.rewardEligible, isFalse);
  });

  test('badges', () {
    final s = score([
      for (var d = 2; d <= 8; d++) rec(d, 15000, hours: hoursAt(7, 2, 7500)),
    ]);
    final earned = {for (final b in s.badges) b.code: b.earned};
    expect(earned['first_walk'], isTrue);
    expect(earned['streak_7'], isTrue);
    expect(earned['steps_100k'], isTrue);
    expect(earned['early_bird'], isTrue);
    expect(earned['steady_timing'], isTrue);
    expect(earned['finisher'], isFalse, reason: 'event not over');
  });

  test('pace is estimated from distance and steps', () {
    final s = score([rec(2, 6000, dist: 4500)]);
    expect(s.fastestPaceKmh, closeTo(4.5, 0.01)); // 4.5 km in 60 min
    expect(score([rec(2, 6000)]).fastestPaceKmh, isNull);
  });

  test('fitHoursToTotal never inflates and caps each hour', () {
    expect(fitHoursToTotal([100, 200], 1000), [100, 200]);
    expect(fitHoursToTotal([500, 500], 500).fold<int>(0, (a, b) => a + b), lessThanOrEqualTo(500));
    expect(fitHoursToTotal([20000, -5], 99999), [14400, 0]);
  });

  test('sensor ledger splits steps into hours and days consistently', () {
    final t = SensorDeltaTracker(SensorLedger());
    t.addReading(0, DateTime(2026, 11, 13, 7, 30));
    t.addReading(600, DateTime(2026, 11, 13, 8, 30)); // 300 in hour 7, 300 in hour 8
    final h = t.hoursFor(DateTime(2026, 11, 13))!;
    expect(h[7], 300);
    expect(h[8], 300);
    expect(h.fold<int>(0, (a, b) => a + b), t.stepsFor(DateTime(2026, 11, 13)));
    final restored = SensorDeltaTracker(SensorLedger.decode(t.ledger.encode()));
    expect(restored.hoursFor(DateTime(2026, 11, 13))![8], 300);
  });

  test('hour labels', () {
    expect(hourLabel(0), '12 AM');
    expect(hourLabel(8), '8 AM');
    expect(hourLabel(12), '12 PM');
    expect(hourLabel(18), '6 PM');
  });
}

