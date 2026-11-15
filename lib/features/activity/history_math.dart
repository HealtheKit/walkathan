import '../../core/time/local_day.dart';

/// Pure calculations over a profile's step history. No I/O, fully tested.
///
/// Simplification (stated in the spec): the CURRENT daily goal is applied to
/// past days too; goal history is not stored.

class DayRecord {
  const DayRecord({required this.steps, this.distanceM, this.kcal, this.floors});
  final int steps;
  final int? distanceM;
  final int? kcal;
  final int? floors;
}

class ActivityHistory {
  const ActivityHistory({
    required this.days,
    required this.restDays,
    required this.goal,
  });

  /// Local date key ('YYYY-MM-DD') -> that day's record.
  final Map<String, DayRecord> days;
  final Set<String> restDays;
  final int goal;

  int stepsOn(DateTime d) => days[dateKey(d)]?.steps ?? 0;
  bool metGoal(DateTime d) => goal > 0 && stepsOn(d) >= goal;
  bool isRest(DateTime d) => restDays.contains(dateKey(d));

  /// Returns a copy where [day]'s record is replaced when [record] has more
  /// steps (used to overlay today's live count on server history).
  ActivityHistory withLive(DateTime day, DayRecord? record) {
    if (record == null || record.steps <= stepsOn(day)) return this;
    return ActivityHistory(
      days: {...days, dateKey(day): record},
      restDays: restDays,
      goal: goal,
    );
  }
}

// ---------------------------------------------------------------- streaks

class StreakInfo {
  const StreakInfo({required this.current, required this.best});
  final int current;
  final int best;
}

/// A streak is a run of days that met the goal. A Rest Day neither breaks
/// the run nor adds to it. Today not being met YET does not break the run.
StreakInfo computeStreak(ActivityHistory h, DateTime today) {
  // Current streak: walk back from today.
  var current = 0;
  var day = startOfDay(today);
  if (!h.metGoal(day) && !h.isRest(day)) {
    day = daysAgo(day, 1); // today still in progress
  }
  for (var i = 0; i < 800; i++) {
    if (h.metGoal(day)) {
      current++;
    } else if (!h.isRest(day)) {
      break;
    }
    day = daysAgo(day, 1);
  }

  // Best streak: walk forward over the whole history.
  var best = 0;
  if (h.days.isNotEmpty) {
    final keys = h.days.keys.toList()..sort();
    final first = DateTime.parse(keys.first);
    var run = 0;
    for (var d = startOfDay(first);
        !d.isAfter(startOfDay(today));
        d = DateTime(d.year, d.month, d.day + 1)) {
      if (h.metGoal(d)) {
        run++;
        if (run > best) best = run;
      } else if (!h.isRest(d)) {
        run = 0;
      }
    }
  }
  if (current > best) best = current;
  return StreakInfo(current: current, best: best);
}

/// Rest days already placed in the Monday-Sunday week containing [day].
int restDaysInWeek(ActivityHistory h, DateTime day) {
  final start = weekStart(day);
  var n = 0;
  for (var i = 0; i < 7; i++) {
    if (h.isRest(DateTime(start.year, start.month, start.day + i))) n++;
  }
  return n;
}

const int kMaxRestDaysPerWeek = 2;

// ---------------------------------------------------------------- series

enum HistoryPeriod { day, week, month, year }

class SeriesPoint {
  const SeriesPoint(this.label, this.steps, {this.date});
  final String label;
  final int steps;
  final DateTime? date;
}

class PeriodSummary {
  const PeriodSummary({
    required this.points,
    required this.total,
    required this.dailyAverage,
    required this.goalsMet,
    required this.distanceM,
    required this.kcal,
    required this.bestDay,
    required this.bestDaySteps,
  });
  final List<SeriesPoint> points;
  final int total;

  /// Average over the days of the period that have already happened.
  final int dailyAverage;
  final int goalsMet;
  final int distanceM;
  final int kcal;
  final DateTime? bestDay;
  final int bestDaySteps;
}

const _weekdayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const _monthLetters = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];

/// The first and last local day of the period containing [anchor].
({DateTime start, DateTime end}) periodRange(HistoryPeriod p, DateTime anchor) {
  switch (p) {
    case HistoryPeriod.day:
      final d = startOfDay(anchor);
      return (start: d, end: d);
    case HistoryPeriod.week:
      final s = weekStart(anchor);
      return (start: s, end: DateTime(s.year, s.month, s.day + 6));
    case HistoryPeriod.month:
      return (
        start: DateTime(anchor.year, anchor.month, 1),
        end: DateTime(anchor.year, anchor.month + 1, 0),
      );
    case HistoryPeriod.year:
      return (start: DateTime(anchor.year, 1, 1), end: DateTime(anchor.year, 12, 31));
  }
}

/// Moves [anchor] one period back (-1) or forward (+1).
DateTime shiftAnchor(HistoryPeriod p, DateTime anchor, int dir) => switch (p) {
      HistoryPeriod.day => DateTime(anchor.year, anchor.month, anchor.day + dir),
      HistoryPeriod.week => DateTime(anchor.year, anchor.month, anchor.day + 7 * dir),
      HistoryPeriod.month => DateTime(anchor.year, anchor.month + dir, 1),
      HistoryPeriod.year => DateTime(anchor.year + dir, 1, 1),
    };

PeriodSummary summarize(
    ActivityHistory h, HistoryPeriod p, DateTime anchor, DateTime today) {
  final range = periodRange(p, anchor);
  final t = startOfDay(today);
  var total = 0, goalsMet = 0, dist = 0, kcal = 0, elapsed = 0, bestSteps = 0;
  DateTime? bestDay;
  final monthTotals = List<int>.filled(12, 0);
  final dayPoints = <SeriesPoint>[];

  for (var d = range.start;
      !d.isAfter(range.end);
      d = DateTime(d.year, d.month, d.day + 1)) {
    final rec = h.days[dateKey(d)];
    final s = rec?.steps ?? 0;
    if (!d.isAfter(t)) elapsed++;
    total += s;
    dist += rec?.distanceM ?? 0;
    kcal += rec?.kcal ?? 0;
    if (h.metGoal(d)) goalsMet++;
    if (s > bestSteps) {
      bestSteps = s;
      bestDay = d;
    }
    monthTotals[d.month - 1] += s;
    if (p != HistoryPeriod.year) {
      final label = switch (p) {
        HistoryPeriod.week => _weekdayLetters[d.weekday - 1],
        HistoryPeriod.month => (d.day == 1 || d.day % 5 == 0) ? '${d.day}' : '',
        _ => '',
      };
      dayPoints.add(SeriesPoint(label, s, date: d));
    }
  }

  final points = p == HistoryPeriod.year
      ? [
          for (var m = 0; m < 12; m++)
            SeriesPoint(_monthLetters[m], monthTotals[m],
                date: DateTime(anchor.year, m + 1, 1)),
        ]
      : dayPoints;

  return PeriodSummary(
    points: points,
    total: total,
    dailyAverage: elapsed == 0 ? 0 : (total / elapsed).round(),
    goalsMet: goalsMet,
    distanceM: dist,
    kcal: kcal,
    bestDay: bestDay,
    bestDaySteps: bestSteps,
  );
}

// ---------------------------------------------------------------- records

class PersonalRecords {
  const PersonalRecords({
    required this.bestDaySteps,
    required this.bestDay,
    required this.bestWeekSteps,
    required this.bestWeekStart,
    required this.bestMonthSteps,
    required this.bestMonth,
    required this.bestStreak,
    required this.lifetimeSteps,
  });
  final int bestDaySteps;
  final DateTime? bestDay;
  final int bestWeekSteps;
  final DateTime? bestWeekStart;
  final int bestMonthSteps;
  final DateTime? bestMonth;
  final int bestStreak;

  /// Total over the loaded history (currently this year and last year).
  final int lifetimeSteps;
}

PersonalRecords computeRecords(ActivityHistory h, DateTime today) {
  var bestDaySteps = 0, lifetime = 0;
  DateTime? bestDay;
  final weeks = <String, int>{};
  final months = <String, int>{};
  h.days.forEach((key, rec) {
    final d = DateTime.parse(key);
    lifetime += rec.steps;
    if (rec.steps > bestDaySteps) {
      bestDaySteps = rec.steps;
      bestDay = d;
    }
    final wk = dateKey(weekStart(d));
    weeks[wk] = (weeks[wk] ?? 0) + rec.steps;
    final mk = '${d.year}-${d.month.toString().padLeft(2, '0')}-01';
    months[mk] = (months[mk] ?? 0) + rec.steps;
  });

  ({int steps, DateTime? at}) top(Map<String, int> m) {
    var s = 0;
    DateTime? at;
    m.forEach((k, v) {
      if (v > s) {
        s = v;
        at = DateTime.parse(k);
      }
    });
    return (steps: s, at: at);
  }

  final w = top(weeks), m = top(months);
  return PersonalRecords(
    bestDaySteps: bestDaySteps,
    bestDay: bestDay,
    bestWeekSteps: w.steps,
    bestWeekStart: w.at,
    bestMonthSteps: m.steps,
    bestMonth: m.at,
    bestStreak: computeStreak(h, today).best,
    lifetimeSteps: lifetime,
  );
}

// ----------------------------------------------------------- achievements

class Achievement {
  const Achievement({
    required this.code,
    required this.title,
    required this.description,
    required this.progress,
  });
  final String code;
  final String title;
  final String description;

  /// 0..1; earned at 1.
  final double progress;
  bool get earned => progress >= 1;
}

List<Achievement> computeAchievements(ActivityHistory h, DateTime today) {
  final rec = computeRecords(h, today);
  final streak = computeStreak(h, today);
  final week = summarize(h, HistoryPeriod.week, today, today);
  double frac(num have, num need) =>
      need <= 0 ? 0 : (have / need).clamp(0, 1).toDouble();

  Achievement a(String code, String title, String desc, double p) =>
      Achievement(code: code, title: title, description: desc, progress: p);

  return [
    // Daily progress
    a('today_goal', 'Goal today', 'Reach your daily goal today',
        frac(h.stepsOn(today), h.goal)),
    a('day_10k', '10K day', 'Walk 10,000 steps in a day', frac(rec.bestDaySteps, 10000)),
    a('day_15k', '15K day', 'Walk 15,000 steps in a day', frac(rec.bestDaySteps, 15000)),
    a('day_20k', '20K day', 'Walk 20,000 steps in a day', frac(rec.bestDaySteps, 20000)),
    // Weekly progress
    a('week_5_goals', '5-day week', 'Reach your goal on 5 days this week',
        frac(week.goalsMet, 5)),
    a('week_50k', '50K week', 'Walk 50,000 steps in a week', frac(rec.bestWeekSteps, 50000)),
    a('week_70k', '70K week', 'Walk 70,000 steps in a week', frac(rec.bestWeekSteps, 70000)),
    a('week_100k', '100K week', 'Walk 100,000 steps in a week', frac(rec.bestWeekSteps, 100000)),
    // Streaks
    a('streak_3', '3-day streak', 'Reach your goal 3 days in a row', frac(streak.best, 3)),
    a('streak_7', '7-day streak', 'Reach your goal 7 days in a row', frac(streak.best, 7)),
    a('streak_30', '30-day streak', 'Reach your goal 30 days in a row', frac(streak.best, 30)),
  ];
}
