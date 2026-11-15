import '../../core/time/local_day.dart';

/// Where a day total came from. The server keeps one total per source and
/// uses the HIGHER of them (never the sum).
enum StepSourceKind {
  /// Apple Health / Health Connect (already de-duplicates the user's own
  /// phone, watch and apps).
  healthStore('health_store'),

  /// The phone's own hardware step counter (Android fallback).
  phoneSensor('phone_sensor');

  const StepSourceKind(this.wire);
  final String wire;

  static StepSourceKind fromWire(String? v) => StepSourceKind.values
      .firstWhere((s) => s.wire == v, orElse: () => StepSourceKind.phoneSensor);
}

/// A day total for one source (cumulative for that local day).
class StepDay {
  StepDay({
    required this.localDate,
    required this.offsetMin,
    required this.source,
    required this.steps,
    this.distanceM,
    this.kcal,
    this.floors,
    this.excludedSteps = 0,
    this.hours,
    this.countedFrom,
    DateTime? observedAt,
  }) : observedAt = observedAt ?? _epoch;

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  /// 'YYYY-MM-DD' in the user's local calendar.
  final String localDate;
  final int offsetMin;
  final StepSourceKind source;
  final int steps;
  final int? distanceM;
  final int? kcal;
  final int? floors;

  /// Steps ignored because they happened during cycling / exercise-machine
  /// sessions. For display only: it is not stored or uploaded.
  final int excludedSteps;

  /// Steps per local hour (24 values), when the source can tell. Used for
  /// "walks at a similar time each day".
  final List<int>? hours;

  /// Set when this total only contains steps taken SINCE this moment (an
  /// organizer reset the counts). Such a total replaces an older, larger one.
  final DateTime? countedFrom;

  /// When this value was read from the source. Lets the server apply the
  /// newest Health reading (which may correct a total downward).
  final DateTime observedAt;

  String get key => '$localDate|${source.wire}';

  StepDay copyWith({int? steps, int? distanceM, int? kcal, int? floors}) =>
      StepDay(
        excludedSteps: excludedSteps,
        hours: hours,
        countedFrom: countedFrom,
        observedAt: observedAt,
        localDate: localDate,
        offsetMin: offsetMin,
        source: source,
        steps: steps ?? this.steps,
        distanceM: distanceM ?? this.distanceM,
        kcal: kcal ?? this.kcal,
        floors: floors ?? this.floors,
      );

  /// Combines two readings of the SAME day and source, mirroring the server:
  ///  * health store: the NEWEST reading wins, even if lower (a later
  ///    exercise-session exclusion corrects the total downward);
  ///  * phone sensor: the LARGER total wins (it never goes down).
  StepDay merge(StepDay other) {
    assert(other.key == key);
    // A total cut at a newer reset always wins, even if it is smaller.
    if (_newerCut(other, this)) return other;
    if (_newerCut(this, other)) return this;
    if (source == StepSourceKind.healthStore) {
      return other.observedAt.isBefore(observedAt) ? this : other;
    }
    return other.steps >= steps ? other : this;
  }

  static bool _newerCut(StepDay a, StepDay b) =>
      a.countedFrom != null &&
      (b.countedFrom == null || a.countedFrom!.isAfter(b.countedFrom!));

  Map<String, dynamic> toJson() => {
        'local_date': localDate,
        'tz_offset_min': offsetMin,
        'source': source.wire,
        'steps': steps,
        'observed_at': observedAt.toUtc().toIso8601String(),
        if (distanceM != null) 'distance_m': distanceM,
        if (kcal != null) 'kcal': kcal,
        if (floors != null) 'floors': floors,
        if (hours != null && hours!.length == 24) 'hours': hours,
        if (countedFrom != null) 'counted_from': countedFrom!.toUtc().toIso8601String(),
      };

  factory StepDay.fromJson(Map<String, dynamic> j) => StepDay(
        localDate: j['local_date'] as String,
        offsetMin: (j['tz_offset_min'] as num).toInt(),
        source: StepSourceKind.fromWire(j['source'] as String?),
        steps: (j['steps'] as num).toInt(),
        distanceM: (j['distance_m'] as num?)?.toInt(),
        kcal: (j['kcal'] as num?)?.toInt(),
        floors: (j['floors'] as num?)?.toInt(),
        observedAt: DateTime.tryParse(j['observed_at'] as String? ?? ''),
        hours: (j['hours'] as List?)?.map((e) => (e as num).toInt()).toList(),
        countedFrom: DateTime.tryParse(j['counted_from'] as String? ?? ''),
      );

  /// Builds a day record for [date] (local calendar day).
  factory StepDay.forDate(
    DateTime date, {
    required StepSourceKind source,
    required int steps,
    int? distanceM,
    int? kcal,
    int? floors,
    int excludedSteps = 0,
    List<int>? hours,
    DateTime? countedFrom,
    DateTime? observedAt,
  }) =>
      StepDay(
        excludedSteps: excludedSteps,
        hours: hours,
        countedFrom: countedFrom,
        observedAt: observedAt ?? DateTime.now(),
        localDate: dateKey(date),
        offsetMin: offsetMinutesFor(date),
        source: source,
        steps: steps,
        distanceM: distanceM,
        kcal: kcal,
        floors: floors,
      );
}

/// The single view of a day from several sources. Matches the server's
/// `recompute_step_day`: the health store wins whenever it has data (it has
/// already excluded cycling / exercise-machine sessions, which the raw phone
/// sensor cannot know about); otherwise the phone sensor. Never the sum.
StepDay? resolveDay(Iterable<StepDay> sameDay) {
  StepDay? health;
  StepDay? sensor;
  for (final d in sameDay) {
    if (d.source == StepSourceKind.healthStore) {
      if (health == null || !d.observedAt.isBefore(health.observedAt)) health = d;
    } else if (sensor == null ||
        StepDay._newerCut(d, sensor) ||
        (!StepDay._newerCut(sensor, d) && d.steps > sensor.steps)) {
      sensor = d;
    }
  }
  return health ?? sensor;
}
