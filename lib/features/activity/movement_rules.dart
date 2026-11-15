import 'package:health/health.dart' show HealthWorkoutActivityType;

/// Rules for which steps are valid: only steps from a person actually
/// walking or running. Not manual entries, and not steps the phone or watch
/// logged while the person was on exercise equipment that does not move them.
///
/// What this can and cannot do:
///  * It CAN remove steps recorded during exercise sessions that the health
///    platform labels as stationary equipment, treadmill / indoor, or cycling.
///  * Steps counted while the phone stayed in one place (shaking it while
///    standing still) are removed using the on-phone GPS record in
///    movement_ledger.dart. Where GPS is off or unavailable nothing is
///    removed: we never subtract what we cannot positively identify.
///  * Sessions only exist if the user's watch/app logged them.

/// Workout types whose steps are NOT counted: the person is not travelling
/// anywhere (exercise bike, treadmill, machines) or not walking at all
/// (cycling). Decision: treadmill sessions do NOT count either.
const Set<HealthWorkoutActivityType> kNonLocomotionWorkouts = {
  HealthWorkoutActivityType.WALKING_TREADMILL, // Android
  HealthWorkoutActivityType.RUNNING_TREADMILL, // Android
  HealthWorkoutActivityType.BIKING, // iOS "cycling": indoor and outdoor
  HealthWorkoutActivityType.BIKING_STATIONARY, // Android indoor bike
  HealthWorkoutActivityType.HAND_CYCLING,
  HealthWorkoutActivityType.ELLIPTICAL,
  HealthWorkoutActivityType.ROWING,
  HealthWorkoutActivityType.ROWING_MACHINE,
  HealthWorkoutActivityType.STAIR_CLIMBING_MACHINE,
};

/// iOS marks indoor sessions (treadmill, indoor walk/run) with the HealthKit
/// metadata key `HKIndoorWorkout`. iOS has no separate "treadmill" type, so
/// this flag is how an indoor run or walk is recognised there.
const String kIosIndoorWorkoutKey = 'HKIndoorWorkout';

bool isIndoorWorkout(Map<String, dynamic>? metadata) {
  final v = metadata?[kIosIndoorWorkoutKey];
  return v == true || v == 1 || v == '1' || v == 'true';
}

/// Whether a workout's steps must be ignored.
bool isExcludedWorkout(HealthWorkoutActivityType type, Map<String, dynamic>? metadata) =>
    kNonLocomotionWorkouts.contains(type) || isIndoorWorkout(metadata);

class TimeSpan {
  const TimeSpan(this.from, this.to);
  final DateTime from;
  final DateTime to;

  bool get isEmpty => !to.isAfter(from);

  @override
  String toString() => 'TimeSpan($from -> $to)';
}

/// Clamps [spans] to [window], drops empties, and merges overlaps so a step
/// is never subtracted twice.
List<TimeSpan> normalizeSpans(Iterable<TimeSpan> spans, TimeSpan window) {
  final clamped = <TimeSpan>[];
  for (final s in spans) {
    final from = s.from.isBefore(window.from) ? window.from : s.from;
    final to = s.to.isAfter(window.to) ? window.to : s.to;
    if (to.isAfter(from)) clamped.add(TimeSpan(from, to));
  }
  clamped.sort((a, b) => a.from.compareTo(b.from));

  final merged = <TimeSpan>[];
  for (final s in clamped) {
    if (merged.isNotEmpty && !s.from.isAfter(merged.last.to)) {
      final last = merged.removeLast();
      merged.add(TimeSpan(last.from, s.to.isAfter(last.to) ? s.to : last.to));
    } else {
      merged.add(s);
    }
  }
  return merged;
}

class AdjustedSteps {
  const AdjustedSteps({required this.steps, required this.excluded});

  /// Steps that count.
  final int steps;

  /// Steps removed because they happened during excluded sessions.
  final int excluded;
}

/// [total] minus the steps recorded inside [sessions] (within [window]).
/// [stepsBetween] must return only non-manual steps for an interval, or null
/// when unknown (treated as zero: we never subtract what we cannot measure).
Future<AdjustedSteps> stepsExcludingSessions({
  required int total,
  required Iterable<TimeSpan> sessions,
  required TimeSpan window,
  required Future<int?> Function(DateTime from, DateTime to) stepsBetween,
}) async {
  var excluded = 0;
  for (final s in normalizeSpans(sessions, window)) {
    final n = await stepsBetween(s.from, s.to);
    if (n != null && n > 0) excluded += n;
  }
  if (excluded > total) excluded = total; // never go negative
  return AdjustedSteps(steps: total - excluded, excluded: excluded);
}

/// Scales hourly values down (never up) so their sum does not exceed
/// [total], and caps each hour at what a person can walk (14,400 = 4 per
/// second). The server rejects hours that exceed the day total.
List<int> fitHoursToTotal(List<int> hours, int total) {
  final capped = [for (final h in hours) h < 0 ? 0 : (h > 14400 ? 14400 : h)];
  final sum = capped.fold<int>(0, (a, b) => a + b);
  if (sum <= total || sum == 0) return capped;
  final out = [for (final h in capped) (h * total / sum).floor()];
  return out;
}
