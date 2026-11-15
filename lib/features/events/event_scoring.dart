import 'dart:math' as math;

import '../../core/time/local_day.dart';

/// Pure scoring for one participant in one event. No I/O; fully tested.
///
/// Definitions (shown to users in plain words):
///  * Active day: at least one valid step.
///  * Low-activity day: some steps, but under 30% of the daily target.
///  * Step consistency: 100 when every event day has the same steps, lower
///    the more days differ (missed days count as zero). 100 x (1 - CV).
///  * Walk window: from the first to the last hour with 200+ steps.
///  * Timing consistency: share of measured days that start within an hour
///    of the person's usual start, whatever time that is.
///  * Active minutes: an ESTIMATE, steps / 100 (a typical walking cadence).

class EventDayRecord {
  const EventDayRecord({required this.date, required this.steps, this.distanceM, this.kcal, this.hours});
  final DateTime date;
  final int steps;
  final int? distanceM;
  final int? kcal;
  final List<int>? hours;

  factory EventDayRecord.fromMap(Map m) => EventDayRecord(
        date: DateTime.parse(m['date'] as String),
        steps: (m['steps'] as num).toInt(),
        distanceM: (m['distance_m'] as num?)?.toInt(),
        kcal: (m['kcal'] as num?)?.toInt(),
        hours: (m['hours'] as List?)?.map((e) => (e as num).toInt()).toList(),
      );
}

class EventConfig {
  const EventConfig({
    required this.startsOn,
    required this.endsOn,
    this.dailyTarget = 8000,
    this.rewardMinSteps,
    this.rewardMinActivePct,
  });
  final DateTime startsOn;
  final DateTime endsOn;
  final int dailyTarget;
  final int? rewardMinSteps;
  final int? rewardMinActivePct;

  int get totalDays => endsOn.difference(startsOn).inDays + 1;
}

enum DayStatus { targetMet, active, low, missed, future }

class WalkWindow {
  const WalkWindow(this.startHour, this.endHour);
  final int startHour; // inclusive
  final int endHour; // exclusive
  int get hours => endHour - startHour;
}

class Badge {
  const Badge(this.code, this.title, this.description, this.earned);
  final String code;
  final String title;
  final String description;
  final bool earned;
}

class Milestone {
  const Milestone(this.steps, this.reached);
  final int steps;
  final bool reached;
}

/// Minimum steps in an hour to count as walking in that hour.
const int kWalkingHourThreshold = 200;

WalkWindow? walkWindow(List<int>? hours) {
  if (hours == null || hours.length != 24) return null;
  int? first, last;
  for (var h = 0; h < 24; h++) {
    if (hours[h] >= kWalkingHourThreshold) {
      first ??= h;
      last = h;
    }
  }
  return first == null ? null : WalkWindow(first, last! + 1);
}

int _median(List<int> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

class EventScore {
  EventScore._({
    required this.config,
    required this.today,
    required this.byDate,
  });

  factory EventScore.compute(EventConfig config, List<EventDayRecord> days, DateTime today) =>
      EventScore._(
        config: config,
        today: startOfDay(today),
        byDate: {for (final d in days) dateKey(d.date): d},
      );

  final EventConfig config;
  final DateTime today;
  final Map<String, EventDayRecord> byDate;

  EventDayRecord? on(DateTime d) => byDate[dateKey(d)];
  int stepsOn(DateTime d) => on(d)?.steps ?? 0;

  DateTime get _start => startOfDay(config.startsOn);
  DateTime get _end => startOfDay(config.endsOn);

  /// Event days up to today (inclusive), oldest first.
  List<DateTime> get elapsedDays {
    final last = today.isBefore(_end) ? today : _end;
    if (last.isBefore(_start)) return const [];
    return [
      for (var d = _start; !d.isAfter(last); d = DateTime(d.year, d.month, d.day + 1)) d,
    ];
  }

  // -------------------------------------------------------------- totals
  int get totalSteps => elapsedDays.fold(0, (a, d) => a + stepsOn(d));
  int get totalDistanceM => elapsedDays.fold(0, (a, d) => a + (on(d)?.distanceM ?? 0));
  int get totalKcal => elapsedDays.fold(0, (a, d) => a + (on(d)?.kcal ?? 0));
  int get daysCompleted => elapsedDays.length;
  int get daysRemaining => math.max(0, config.totalDays - daysCompleted);
  double get eventProgress => config.totalDays == 0 ? 0 : daysCompleted / config.totalDays;
  int get averageDaily => daysCompleted == 0 ? 0 : (totalSteps / daysCompleted).round();

  /// Estimated, from steps (100 steps a minute).
  int estimatedActiveMinutes(int steps) => (steps / 100).round();

  // --------------------------------------------------------- consistency
  int get activeDays => elapsedDays.where((d) => stepsOn(d) > 0).length;
  double get activeDayRate => daysCompleted == 0 ? 0 : activeDays / daysCompleted;

  /// 0..100, see the header.
  int get stepConsistency {
    final v = [for (final d in elapsedDays) stepsOn(d)];
    if (v.length < 2) return v.isEmpty || v.first == 0 ? 0 : 100;
    final mean = v.reduce((a, b) => a + b) / v.length;
    if (mean == 0) return 0;
    final variance = v.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / v.length;
    final cv = math.sqrt(variance) / mean;
    return (100 * (1 - math.min(cv, 1))).round();
  }

  /// Consecutive active days ending today (today not yet walked doesn't break it).
  int get currentStreak {
    final days = elapsedDays;
    var i = days.length - 1;
    if (i >= 0 && stepsOn(days[i]) == 0 && days[i] == today) i--;
    var n = 0;
    for (; i >= 0 && stepsOn(days[i]) > 0; i--) {
      n++;
    }
    return n;
  }

  int get longestStreak {
    var best = 0, run = 0;
    for (final d in elapsedDays) {
      run = stepsOn(d) > 0 ? run + 1 : 0;
      best = math.max(best, run);
    }
    return best;
  }

  /// Walking again after one or more missed days: the current run of
  /// active days follows a gap. Returns the gap length, or null.
  int? get recoveredAfterMissed {
    final days = elapsedDays.where((d) => d != today || stepsOn(d) > 0).toList();
    var i = days.length - 1;
    if (i < 0 || stepsOn(days[i]) == 0) return null;
    while (i >= 0 && stepsOn(days[i]) > 0) {
      i--; // walk back over the current active run
    }
    var gap = 0;
    while (i >= 0 && stepsOn(days[i]) == 0) {
      gap++;
      i--;
    }
    // a gap that reaches back to the event start is a late start, not a recovery
    return gap == 0 || i < 0 ? null : gap;
  }

  DayStatus statusOf(DateTime day) {
    final d = startOfDay(day);
    if (d.isAfter(today)) return DayStatus.future;
    final s = stepsOn(d);
    if (s >= config.dailyTarget && s > 0) return DayStatus.targetMet;
    if (s == 0) return d == today ? DayStatus.low : DayStatus.missed;
    if (s < config.dailyTarget * 0.3) return DayStatus.low;
    return DayStatus.active;
  }

  int get targetMetDays => elapsedDays.where((d) => statusOf(d) == DayStatus.targetMet).length;

  // -------------------------------------------------------------- timing
  List<WalkWindow> get _windows => [
        for (final d in elapsedDays)
          if (walkWindow(on(d)?.hours) case final w?) w,
      ];

  int get timedDays => _windows.length;
  int? get usualStartHour => _windows.isEmpty ? null : _median([for (final w in _windows) w.startHour]);
  int? get usualEndHour => _windows.isEmpty ? null : _median([for (final w in _windows) w.endHour]);
  double? get averageWalkHours => _windows.isEmpty
      ? null
      : _windows.map((w) => w.hours).reduce((a, b) => a + b) / _windows.length;

  /// 0..100; null until 3 days have hourly data.
  int? get timingConsistency {
    final w = _windows;
    if (w.length < 3) return null;
    final usual = usualStartHour!;
    final near = w.where((x) => (x.startHour - usual).abs() <= 1).length;
    return (100 * near / w.length).round();
  }

  int get earlyMorningDays => _windows.where((w) => w.startHour < 8).length;

  // -------------------------------------------------------------- weekly
  ({int total, int average, DateTime? best, DateTime? worst}) week(DateTime anyDay) {
    final start = weekStart(anyDay);
    var total = 0, counted = 0;
    DateTime? best, worst;
    for (var i = 0; i < 7; i++) {
      final d = DateTime(start.year, start.month, start.day + i);
      if (d.isBefore(_start) || d.isAfter(_end) || d.isAfter(today)) continue;
      final s = stepsOn(d);
      total += s;
      counted++;
      if (best == null || s > stepsOn(best)) best = d;
      if (worst == null || s < stepsOn(worst)) worst = d;
    }
    return (total: total, average: counted == 0 ? 0 : (total / counted).round(), best: best, worst: worst);
  }

  ({int total, int average, DateTime? best, DateTime? worst}) get thisWeek => week(today);
  ({int total, int average, DateTime? best, DateTime? worst}) get lastWeek =>
      week(DateTime(today.year, today.month, today.day - 7));

  // -------------------------------------------------------------- trends
  List<({DateTime date, int steps, int cumulative})> get trend {
    var c = 0;
    return [
      for (final d in elapsedDays) (date: d, steps: stepsOn(d), cumulative: c += stepsOn(d)),
    ];
  }

  // ------------------------------------------------------- personal bests
  ({DateTime? date, int steps}) get bestDay {
    DateTime? at;
    var best = 0;
    for (final d in elapsedDays) {
      if (stepsOn(d) > best) {
        best = stepsOn(d);
        at = d;
      }
    }
    return (date: at, steps: best);
  }

  int get bestWeekTotal {
    final seen = <String>{};
    var best = 0;
    for (final d in elapsedDays) {
      final k = dateKey(weekStart(d));
      if (seen.add(k)) best = math.max(best, week(d).total);
    }
    return best;
  }

  /// Longest walk window in hours (from hourly data).
  int get longestWalkHours => _windows.fold(0, (a, w) => math.max(a, w.hours));

  /// Fastest average pace across days, in km/h (ESTIMATED: distance over
  /// estimated active minutes). Null without distance data.
  double? get fastestPaceKmh {
    double? best;
    for (final d in elapsedDays) {
      final r = on(d);
      if (r == null || r.steps < 1000 || (r.distanceM ?? 0) <= 0) continue;
      final minutes = estimatedActiveMinutes(r.steps);
      final kmh = (r.distanceM! / 1000) / (minutes / 60);
      if (best == null || kmh > best) best = kmh;
    }
    return best;
  }

  // ---------------------------------------------- milestones and badges
  List<Milestone> get milestones {
    final targets = <int>{10000, 50000, 100000, 250000, 500000, 1000000};
    if (config.rewardMinSteps != null && config.rewardMinSteps! > 0) {
      targets.add(config.rewardMinSteps!);
    }
    return [for (final t in targets.toList()..sort()) Milestone(t, totalSteps >= t)];
  }

  Milestone? get nextMilestone {
    for (final m in milestones) {
      if (!m.reached) return m;
    }
    return null;
  }

  bool get eventEnded => today.isAfter(_end);

  bool get rewardEligible {
    if (config.rewardMinSteps == null && config.rewardMinActivePct == null) return false;
    final stepsOk = config.rewardMinSteps == null || totalSteps >= config.rewardMinSteps!;
    final daysOk = config.rewardMinActivePct == null ||
        (config.totalDays > 0 && 100 * activeDays / config.totalDays >= config.rewardMinActivePct!);
    return stepsOk && daysOk;
  }

  List<Badge> get badges => [
        Badge('first_walk', 'First walk', 'Record steps on any event day', activeDays > 0),
        Badge('streak_7', '7-day streak', 'Walk 7 days in a row', longestStreak >= 7),
        Badge('steps_100k', '100K steps', 'Reach 100,000 steps in the event', totalSteps >= 100000),
        Badge('early_bird', 'Early bird', 'Start walking before 8 AM on 3 days', earlyMorningDays >= 3),
        Badge('steady_timing', 'Steady timing', 'Walk at a similar time on most days (5+ days)',
            timedDays >= 5 && (timingConsistency ?? 0) >= 70),
        Badge('finisher', 'Finisher', 'Be active on at least 80% of event days by the end',
            eventEnded && config.totalDays > 0 && activeDays / config.totalDays >= 0.8),
      ];
}

String hourLabel(int h) {
  final hh = h % 24;
  final suffix = hh < 12 ? 'AM' : 'PM';
  final twelve = hh % 12 == 0 ? 12 : hh % 12;
  return '$twelve $suffix';
}
