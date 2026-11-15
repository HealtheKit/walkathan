import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/core/time/local_day.dart';
import 'package:walkathan/features/activity/history_math.dart';

/// 2026-11-13 is a Friday; its week is Mon 9 .. Sun 15.
final today = DateTime(2026, 11, 13, 14);

ActivityHistory hist(Map<String, int> steps,
        {Set<String> rest = const {}, int goal = 8000}) =>
    ActivityHistory(
      days: {
        for (final e in steps.entries)
          e.key: DayRecord(steps: e.value, distanceM: e.value * 7 ~/ 10, kcal: e.value ~/ 25),
      },
      restDays: rest,
      goal: goal,
    );

void main() {
  group('computeStreak', () {
    test('counts consecutive goal days ending today', () {
      final h = hist({'2026-11-11': 9000, '2026-11-12': 8000, '2026-11-13': 8500});
      expect(computeStreak(h, today).current, 3);
    });

    test('today not met yet does not break the streak', () {
      final h = hist({'2026-11-11': 9000, '2026-11-12': 8000, '2026-11-13': 1200});
      expect(computeStreak(h, today).current, 2);
    });

    test('a missed day breaks it', () {
      final h = hist({'2026-11-10': 9000, '2026-11-11': 100, '2026-11-12': 8000});
      expect(computeStreak(h, today).current, 1);
    });

    test('a rest day keeps the streak alive but does not add to it', () {
      final h = hist(
        {'2026-11-10': 9000, '2026-11-12': 8000, '2026-11-13': 8100},
        rest: {'2026-11-11'},
      );
      expect(computeStreak(h, today).current, 3);
    });

    test('rest day today keeps yesterday\'s streak', () {
      final h = hist({'2026-11-11': 9000, '2026-11-12': 8000}, rest: {'2026-11-13'});
      expect(computeStreak(h, today).current, 2);
    });

    test('rest days alone are not a streak', () {
      final h = hist({}, rest: {'2026-11-12', '2026-11-13'});
      expect(computeStreak(h, today).current, 0);
    });

    test('best streak is found in the past and survives a later break', () {
      final h = hist({
        '2026-10-01': 9000, '2026-10-02': 9000, '2026-10-03': 9000, '2026-10-04': 9000,
        '2026-10-05': 10,
        '2026-11-12': 9000, '2026-11-13': 9000,
      });
      final s = computeStreak(h, today);
      expect(s.best, 4);
      expect(s.current, 2);
    });

    test('no history gives zero', () {
      final s = computeStreak(hist({}), today);
      expect(s.current, 0);
      expect(s.best, 0);
    });

    test('exactly the goal counts; one step short does not', () {
      expect(computeStreak(hist({'2026-11-13': 8000}), today).current, 1);
      expect(computeStreak(hist({'2026-11-13': 7999}), today).current, 0);
    });
  });

  test('restDaysInWeek counts only the Monday-Sunday week', () {
    final h = hist({}, rest: {'2026-11-08', '2026-11-09', '2026-11-15', '2026-11-16'});
    expect(restDaysInWeek(h, today), 2); // 9th (Mon) and 15th (Sun)
  });

  group('periodRange / shiftAnchor', () {
    test('week is Monday to Sunday', () {
      final r = periodRange(HistoryPeriod.week, today);
      expect(dateKey(r.start), '2026-11-09');
      expect(dateKey(r.end), '2026-11-15');
    });
    test('month handles length and leap years', () {
      expect(dateKey(periodRange(HistoryPeriod.month, DateTime(2024, 2, 10)).end), '2024-02-29');
      expect(dateKey(periodRange(HistoryPeriod.month, DateTime(2026, 2, 10)).end), '2026-02-28');
    });
    test('shifting crosses month and year boundaries', () {
      expect(dateKey(shiftAnchor(HistoryPeriod.month, DateTime(2026, 1, 31), -1)), '2025-12-01');
      expect(dateKey(shiftAnchor(HistoryPeriod.week, DateTime(2026, 1, 2), -1)), '2025-12-26');
      expect(shiftAnchor(HistoryPeriod.year, today, 1).year, 2027);
    });
  });

  group('summarize', () {
    final h = hist({
      '2026-11-09': 8000, '2026-11-10': 4000, '2026-11-11': 12000, '2026-11-13': 2000,
      '2026-10-20': 30000, '2026-01-05': 500,
    });

    test('week: 7 points, totals, average over elapsed days only', () {
      final s = summarize(h, HistoryPeriod.week, today, today);
      expect(s.points.length, 7);
      expect(s.points.map((p) => p.label).join(), 'MTWTFSS');
      expect(s.total, 26000);
      expect(s.dailyAverage, 26000 ~/ 5); // Mon..Fri have happened
      expect(s.goalsMet, 2);
      expect(s.bestDaySteps, 12000);
      expect(dateKey(s.bestDay!), '2026-11-11');
      expect(s.distanceM, greaterThan(0));
    });

    test('month: one point per day', () {
      final s = summarize(h, HistoryPeriod.month, today, today);
      expect(s.points.length, 30);
      expect(s.total, 26000);
    });

    test('year: 12 monthly totals', () {
      final s = summarize(h, HistoryPeriod.year, today, today);
      expect(s.points.length, 12);
      expect(s.points[9].steps, 30000); // October
      expect(s.points[0].steps, 500);
      expect(s.total, 56500);
      expect(s.bestDaySteps, 30000);
    });

    test('a past period averages over all its days; an empty one is zero', () {
      final s = summarize(h, HistoryPeriod.month, DateTime(2026, 10, 1), today);
      expect(s.dailyAverage, (30000 / 31).round());
      final empty = summarize(h, HistoryPeriod.month, DateTime(2026, 3, 1), today);
      expect(empty.total, 0);
      expect(empty.bestDay, isNull);
    });

    test('day: single point', () {
      final s = summarize(h, HistoryPeriod.day, DateTime(2026, 11, 11), today);
      expect(s.total, 12000);
      expect(s.points.length, 1);
    });
  });

  test('computeRecords finds best day, week, month and lifetime total', () {
    final h = hist({
      '2026-11-09': 8000, '2026-11-10': 9000, // week of Nov 9: 17000
      '2026-10-20': 15000,                    // week of Oct 19: 15000
      '2026-10-21': 1000,                     // -> 16000; October total 16000
    });
    final r = computeRecords(h, today);
    expect(r.bestDaySteps, 15000);
    expect(dateKey(r.bestDay!), '2026-10-20');
    expect(r.bestWeekSteps, 17000);
    expect(dateKey(r.bestWeekStart!), '2026-11-09');
    expect(r.bestMonthSteps, 17000);
    expect(r.bestMonth!.month, 11);
    expect(r.lifetimeSteps, 33000);
    expect(r.bestStreak, 2);
  });

  group('computeAchievements', () {
    Achievement get(List<Achievement> l, String code) =>
        l.firstWhere((a) => a.code == code);

    test('earned and partial progress', () {
      final h = hist({
        '2026-11-09': 12000, '2026-11-10': 9000, '2026-11-11': 8000, '2026-11-13': 4000,
      });
      final l = computeAchievements(h, today);
      expect(get(l, 'day_10k').earned, isTrue);
      expect(get(l, 'day_20k').earned, isFalse);
      expect(get(l, 'day_20k').progress, closeTo(0.6, 0.001));
      expect(get(l, 'today_goal').progress, closeTo(0.5, 0.001));
      expect(get(l, 'streak_3').earned, isTrue);
      expect(get(l, 'streak_7').earned, isFalse);
      expect(get(l, 'week_5_goals').progress, closeTo(0.6, 0.001));
    });

    test('nothing earned with no history; progress stays within 0..1', () {
      final l = computeAchievements(hist({}), today);
      expect(l.any((a) => a.earned), isFalse);
      final big = computeAchievements(hist({'2026-11-13': 99999}), today);
      expect(big.every((a) => a.progress >= 0 && a.progress <= 1), isTrue);
    });
  });

  test('withLive overlays today only when the live count is higher', () {
    final h = hist({'2026-11-13': 3000});
    expect(h.withLive(today, const DayRecord(steps: 3500)).stepsOn(today), 3500);
    expect(h.withLive(today, const DayRecord(steps: 100)).stepsOn(today), 3000);
    expect(h.withLive(today, null).stepsOn(today), 3000);
  });
}
