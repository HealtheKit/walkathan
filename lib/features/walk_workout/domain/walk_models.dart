/// Domain models for the Walk workout feature. Everything is stored in SI
/// units (metres, seconds, m/s); units are only applied when displaying, so
/// switching km/miles mid-walk can never corrupt recorded data.
library;

enum WalkSessionStatus {
  idle,
  preparing,
  countingDown,
  tracking,
  paused,
  autoPaused,
  gpsWeak,
  saving,

  /// Finished, waiting for the user to save or discard.
  awaitingSave,
  completed,
  discarded,
  error;

  /// A walk exists and must stay visible across the app.
  bool get isLive => switch (this) {
        idle || completed || discarded => false,
        _ => true,
      };

  /// Metrics are accumulating.
  bool get isRecording => this == tracking || this == gpsWeak;

  bool get isPaused => this == paused || this == autoPaused;

  String get label => switch (this) {
        idle => 'Ready',
        preparing => 'Starting…',
        countingDown => 'Starting…',
        tracking => 'Tracking',
        paused => 'Paused',
        autoPaused => 'Auto-paused',
        gpsWeak => 'GPS weak',
        saving => 'Saving…',
        awaitingSave => 'Finished',
        completed => 'Saved',
        discarded => 'Discarded',
        error => 'Error',
      };
}

/// Kept for API parity with the spec.
typedef WorkoutStatus = WalkSessionStatus;

enum GoalType {
  open('Open', ''),
  time('Time', 'min'),
  distance('Distance', 'km'),
  calories('Calories', 'kcal'),
  steps('Steps', 'steps');

  const GoalType(this.label, this.unit);
  final String label;
  final String unit;
}

enum UnitSystem { metric, imperial }

enum VoiceInterval { everyUnit, everyFiveMinutes, off }

class WorkoutGoal {
  const WorkoutGoal({this.type = GoalType.open, this.target = 0});

  final GoalType type;

  /// time: seconds · distance: metres · calories: kcal · steps: steps.
  final double target;

  bool get isOpen => type == GoalType.open || target <= 0;

  Map<String, dynamic> toJson() => {'type': type.name, 'target': target};
  factory WorkoutGoal.fromJson(Map<String, dynamic> j) => WorkoutGoal(
        type: GoalType.values.firstWhere((t) => t.name == j['type'], orElse: () => GoalType.open),
        target: (j['target'] as num?)?.toDouble() ?? 0,
      );
}

class WorkoutSettings {
  const WorkoutSettings({
    this.useGps = true,
    this.voiceCoaching = true,
    this.voiceInterval = VoiceInterval.everyUnit,
    this.autoPause = true,
    this.keepScreenOn = true,
    this.heartRate = true,
    this.musicControls = false,
    this.units = UnitSystem.metric,
  });

  final bool useGps;
  final bool voiceCoaching;
  final VoiceInterval voiceInterval;
  final bool autoPause;
  final bool keepScreenOn;
  final bool heartRate;
  final bool musicControls;
  final UnitSystem units;

  WorkoutSettings copyWith({
    bool? useGps,
    bool? voiceCoaching,
    VoiceInterval? voiceInterval,
    bool? autoPause,
    bool? keepScreenOn,
    bool? heartRate,
    bool? musicControls,
    UnitSystem? units,
  }) =>
      WorkoutSettings(
        useGps: useGps ?? this.useGps,
        voiceCoaching: voiceCoaching ?? this.voiceCoaching,
        voiceInterval: voiceInterval ?? this.voiceInterval,
        autoPause: autoPause ?? this.autoPause,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        heartRate: heartRate ?? this.heartRate,
        musicControls: musicControls ?? this.musicControls,
        units: units ?? this.units,
      );

  Map<String, dynamic> toJson() => {
        'useGps': useGps,
        'voice': voiceCoaching,
        'voiceInterval': voiceInterval.name,
        'autoPause': autoPause,
        'keepScreenOn': keepScreenOn,
        'heartRate': heartRate,
        'music': musicControls,
        'units': units.name,
      };

  factory WorkoutSettings.fromJson(Map<String, dynamic> j) => WorkoutSettings(
        useGps: j['useGps'] != false,
        voiceCoaching: j['voice'] != false,
        voiceInterval: VoiceInterval.values
            .firstWhere((v) => v.name == j['voiceInterval'], orElse: () => VoiceInterval.everyUnit),
        autoPause: j['autoPause'] != false,
        keepScreenOn: j['keepScreenOn'] != false,
        heartRate: j['heartRate'] != false,
        musicControls: j['music'] == true,
        units: j['units'] == 'imperial' ? UnitSystem.imperial : UnitSystem.metric,
      );
}

/// Used for calorie and heart-rate-zone estimates.
class UserProfile {
  const UserProfile({this.age = 35, this.sex, this.heightCm = 170, this.weightKg = 70});
  final int age;
  final String? sex;
  final double heightCm;
  final double weightKg;

  int get maxHeartRate => 220 - age;
}

class LocationPoint {
  const LocationPoint({
    required this.lat,
    required this.lon,
    required this.tMs,
    this.altitude,
    this.accuracyM = 5,
  });
  final double lat;
  final double lon;

  /// Milliseconds since epoch.
  final int tMs;
  final double? altitude;
  final double accuracyM;

  List<num?> toJson() => [lat, lon, tMs, altitude, accuracyM];
  factory LocationPoint.fromJson(List j) => LocationPoint(
        lat: (j[0] as num).toDouble(),
        lon: (j[1] as num).toDouble(),
        tMs: (j[2] as num).toInt(),
        altitude: (j[3] as num?)?.toDouble(),
        accuracyM: (j[4] as num?)?.toDouble() ?? 5,
      );
}

/// A stretch of the route recorded without a pause.
class RouteSegment {
  const RouteSegment(this.points);
  final List<LocationPoint> points;
}

class HeartRateSample {
  const HeartRateSample(this.tSec, this.bpm);
  final int tSec;
  final int bpm;
}

class StepSample {
  const StepSample(this.tSec, this.steps);
  final int tSec;
  final int steps;
}

class ElevationSample {
  const ElevationSample(this.tSec, this.metres);
  final int tSec;
  final double metres;
}

/// One point of the live chart (sampled every few seconds of active time).
class WorkoutMetric {
  const WorkoutMetric({required this.tSec, required this.speed, this.bpm, this.altitude});
  final int tSec;

  /// m/s
  final double speed;
  final int? bpm;
  final double? altitude;

  List<num?> toJson() => [tSec, speed, bpm, altitude];
  factory WorkoutMetric.fromJson(List j) => WorkoutMetric(
        tSec: (j[0] as num).toInt(),
        speed: (j[1] as num).toDouble(),
        bpm: (j[2] as num?)?.toInt(),
        altitude: (j[3] as num?)?.toDouble(),
      );
}

class Lap {
  const Lap({
    required this.index,
    required this.durationMs,
    required this.distanceM,
    required this.kcal,
  });
  final int index;
  final int durationMs;
  final double distanceM;
  final double kcal;

  Map<String, dynamic> toJson() =>
      {'i': index, 'ms': durationMs, 'm': distanceM, 'kcal': kcal};
  factory Lap.fromJson(Map<String, dynamic> j) => Lap(
        index: (j['i'] as num).toInt(),
        durationMs: (j['ms'] as num).toInt(),
        distanceM: (j['m'] as num).toDouble(),
        kcal: (j['kcal'] as num).toDouble(),
      );
}

/// Time taken for one full kilometre (always stored per km).
class Split {
  const Split({required this.index, required this.durationMs});
  final int index;
  final int durationMs;

  Map<String, dynamic> toJson() => {'i': index, 'ms': durationMs};
  factory Split.fromJson(Map<String, dynamic> j) =>
      Split(index: (j['i'] as num).toInt(), durationMs: (j['ms'] as num).toInt());
}

/// THE live walk. One instance at most exists in the app (see
/// WalkSessionController). Immutable; persisted as JSON for recovery.
class WalkSession {
  const WalkSession({
    required this.id,
    required this.status,
    required this.startedAt,
    required this.settings,
    required this.goal,
    this.countdown = 0,
    this.activeMs = 0,
    this.lastResumeAt,
    this.pausedMs = 0,
    this.pausedAt,
    this.endedAt,
    this.distanceM = 0,
    this.steps = 0,
    this.kcal = 0,
    this.currentSpeed = 0,
    this.maxSpeed = 0,
    this.cadence = 0,
    this.maxCadence = 0,
    this.currentHr,
    this.maxHr = 0,
    this.hrSum = 0,
    this.hrCount = 0,
    this.zoneMs = const [0, 0, 0, 0, 0],
    this.elevGain = 0,
    this.elevLoss = 0,
    this.altitude,
    this.gpsAccuracyM,
    this.route = const [],
    this.series = const [],
    this.laps = const [],
    this.splits = const [],
    this.lapStartMs = 0,
    this.lapStartDistanceM = 0,
    this.lapStartKcal = 0,
    this.splitStartMs = 0,
    this.goalReached = false,
    this.autoPauseReason,
    this.recovered = false,
    this.errorMessage,
    this.title = 'Walk',
    this.note = '',
    this.savedAt,
  });

  final String id;
  final WalkSessionStatus status;
  final DateTime startedAt;
  final WorkoutSettings settings;
  final WorkoutGoal goal;

  /// Seconds left on the 3-2-1 countdown.
  final int countdown;

  /// Active (moving) time banked up to [lastResumeAt]. The live value is
  /// always recomputed from timestamps, never from a ticking counter.
  final int activeMs;
  final DateTime? lastResumeAt;
  final int pausedMs;
  final DateTime? pausedAt;
  final DateTime? endedAt;

  final double distanceM;
  final int steps;
  final double kcal;

  /// m/s
  final double currentSpeed;
  final double maxSpeed;

  /// steps per minute
  final int cadence;
  final int maxCadence;

  final int? currentHr;
  final int maxHr;
  final int hrSum;
  final int hrCount;

  /// Milliseconds in each heart-rate zone: rest, warm-up, fat burn, cardio, peak.
  final List<int> zoneMs;

  final double elevGain;
  final double elevLoss;
  final double? altitude;

  /// null = no GPS fix at all.
  final double? gpsAccuracyM;

  final List<LocationPoint> route;
  final List<WorkoutMetric> series;
  final List<Lap> laps;
  final List<Split> splits;
  final int lapStartMs;
  final double lapStartDistanceM;
  final double lapStartKcal;
  final int splitStartMs;

  final bool goalReached;
  final String? autoPauseReason;

  /// Rebuilt from storage after the app was closed.
  final bool recovered;
  final String? errorMessage;
  final String title;
  final String note;

  /// When the session was last written to storage.
  final DateTime? savedAt;

  /// Moving time at [now].
  Duration activeDuration(DateTime now) => Duration(
      milliseconds: activeMs +
          (lastResumeAt == null ? 0 : now.difference(lastResumeAt!).inMilliseconds.clamp(0, 1 << 40)));

  /// Paused time at [now].
  Duration pausedDuration(DateTime now) => Duration(
      milliseconds: pausedMs +
          (pausedAt == null ? 0 : now.difference(pausedAt!).inMilliseconds.clamp(0, 1 << 40)));

  /// Wall-clock time since the walk started (or until it ended).
  Duration totalDuration(DateTime now) => (endedAt ?? now).difference(startedAt);

  int? get avgHr => hrCount == 0 ? null : (hrSum / hrCount).round();

  /// Progress towards the goal, 0..1 (0 for an open goal).
  double goalProgress(DateTime now) {
    if (goal.isOpen) return 0;
    final done = switch (goal.type) {
      GoalType.time => activeDuration(now).inSeconds.toDouble(),
      GoalType.distance => distanceM,
      GoalType.calories => kcal,
      GoalType.steps => steps.toDouble(),
      GoalType.open => 0.0,
    };
    return (done / goal.target).clamp(0.0, 1.0);
  }

  WalkSession copyWith({
    WalkSessionStatus? status,
    WorkoutSettings? settings,
    int? countdown,
    int? activeMs,
    DateTime? lastResumeAt,
    bool clearLastResumeAt = false,
    int? pausedMs,
    DateTime? pausedAt,
    bool clearPausedAt = false,
    DateTime? endedAt,
    double? distanceM,
    int? steps,
    double? kcal,
    double? currentSpeed,
    double? maxSpeed,
    int? cadence,
    int? maxCadence,
    int? currentHr,
    bool clearHr = false,
    int? maxHr,
    int? hrSum,
    int? hrCount,
    List<int>? zoneMs,
    double? elevGain,
    double? elevLoss,
    double? altitude,
    double? gpsAccuracyM,
    bool clearGps = false,
    List<LocationPoint>? route,
    List<WorkoutMetric>? series,
    List<Lap>? laps,
    List<Split>? splits,
    int? lapStartMs,
    double? lapStartDistanceM,
    double? lapStartKcal,
    int? splitStartMs,
    bool? goalReached,
    String? autoPauseReason,
    bool clearAutoPauseReason = false,
    bool? recovered,
    String? errorMessage,
    String? title,
    String? note,
    DateTime? savedAt,
  }) =>
      WalkSession(
        id: id,
        startedAt: startedAt,
        goal: goal,
        status: status ?? this.status,
        settings: settings ?? this.settings,
        countdown: countdown ?? this.countdown,
        activeMs: activeMs ?? this.activeMs,
        lastResumeAt: clearLastResumeAt ? null : (lastResumeAt ?? this.lastResumeAt),
        pausedMs: pausedMs ?? this.pausedMs,
        pausedAt: clearPausedAt ? null : (pausedAt ?? this.pausedAt),
        endedAt: endedAt ?? this.endedAt,
        distanceM: distanceM ?? this.distanceM,
        steps: steps ?? this.steps,
        kcal: kcal ?? this.kcal,
        currentSpeed: currentSpeed ?? this.currentSpeed,
        maxSpeed: maxSpeed ?? this.maxSpeed,
        cadence: cadence ?? this.cadence,
        maxCadence: maxCadence ?? this.maxCadence,
        currentHr: clearHr ? null : (currentHr ?? this.currentHr),
        maxHr: maxHr ?? this.maxHr,
        hrSum: hrSum ?? this.hrSum,
        hrCount: hrCount ?? this.hrCount,
        zoneMs: zoneMs ?? this.zoneMs,
        elevGain: elevGain ?? this.elevGain,
        elevLoss: elevLoss ?? this.elevLoss,
        altitude: altitude ?? this.altitude,
        gpsAccuracyM: clearGps ? null : (gpsAccuracyM ?? this.gpsAccuracyM),
        route: route ?? this.route,
        series: series ?? this.series,
        laps: laps ?? this.laps,
        splits: splits ?? this.splits,
        lapStartMs: lapStartMs ?? this.lapStartMs,
        lapStartDistanceM: lapStartDistanceM ?? this.lapStartDistanceM,
        lapStartKcal: lapStartKcal ?? this.lapStartKcal,
        splitStartMs: splitStartMs ?? this.splitStartMs,
        goalReached: goalReached ?? this.goalReached,
        autoPauseReason: clearAutoPauseReason ? null : (autoPauseReason ?? this.autoPauseReason),
        recovered: recovered ?? this.recovered,
        errorMessage: errorMessage ?? this.errorMessage,
        title: title ?? this.title,
        note: note ?? this.note,
        savedAt: savedAt ?? this.savedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status.name,
        'startedAt': startedAt.toIso8601String(),
        'settings': settings.toJson(),
        'goal': goal.toJson(),
        'countdown': countdown,
        'activeMs': activeMs,
        'lastResumeAt': lastResumeAt?.toIso8601String(),
        'pausedMs': pausedMs,
        'pausedAt': pausedAt?.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'distanceM': distanceM,
        'steps': steps,
        'kcal': kcal,
        'maxSpeed': maxSpeed,
        'maxCadence': maxCadence,
        'maxHr': maxHr,
        'hrSum': hrSum,
        'hrCount': hrCount,
        'zoneMs': zoneMs,
        'elevGain': elevGain,
        'elevLoss': elevLoss,
        'altitude': altitude,
        'route': [for (final p in route) p.toJson()],
        'series': [for (final m in series) m.toJson()],
        'laps': [for (final l in laps) l.toJson()],
        'splits': [for (final s in splits) s.toJson()],
        'lapStartMs': lapStartMs,
        'lapStartDistanceM': lapStartDistanceM,
        'lapStartKcal': lapStartKcal,
        'splitStartMs': splitStartMs,
        'goalReached': goalReached,
        'autoPauseReason': autoPauseReason,
        'title': title,
        'note': note,
        'savedAt': savedAt?.toIso8601String(),
      };

  factory WalkSession.fromJson(Map<String, dynamic> j) {
    DateTime? dt(String k) => DateTime.tryParse((j[k] as String?) ?? '');
    return WalkSession(
      id: j['id'] as String,
      status: WalkSessionStatus.values
          .firstWhere((s) => s.name == j['status'], orElse: () => WalkSessionStatus.paused),
      startedAt: dt('startedAt') ?? DateTime.now(),
      settings: WorkoutSettings.fromJson(Map<String, dynamic>.from(j['settings'] as Map? ?? {})),
      goal: WorkoutGoal.fromJson(Map<String, dynamic>.from(j['goal'] as Map? ?? {})),
      countdown: (j['countdown'] as num?)?.toInt() ?? 0,
      activeMs: (j['activeMs'] as num?)?.toInt() ?? 0,
      lastResumeAt: dt('lastResumeAt'),
      pausedMs: (j['pausedMs'] as num?)?.toInt() ?? 0,
      pausedAt: dt('pausedAt'),
      endedAt: dt('endedAt'),
      distanceM: (j['distanceM'] as num?)?.toDouble() ?? 0,
      steps: (j['steps'] as num?)?.toInt() ?? 0,
      kcal: (j['kcal'] as num?)?.toDouble() ?? 0,
      maxSpeed: (j['maxSpeed'] as num?)?.toDouble() ?? 0,
      maxCadence: (j['maxCadence'] as num?)?.toInt() ?? 0,
      maxHr: (j['maxHr'] as num?)?.toInt() ?? 0,
      hrSum: (j['hrSum'] as num?)?.toInt() ?? 0,
      hrCount: (j['hrCount'] as num?)?.toInt() ?? 0,
      zoneMs: [for (final v in (j['zoneMs'] as List? ?? const [0, 0, 0, 0, 0])) (v as num).toInt()],
      elevGain: (j['elevGain'] as num?)?.toDouble() ?? 0,
      elevLoss: (j['elevLoss'] as num?)?.toDouble() ?? 0,
      altitude: (j['altitude'] as num?)?.toDouble(),
      route: [for (final p in (j['route'] as List? ?? const [])) LocationPoint.fromJson(p as List)],
      series: [for (final m in (j['series'] as List? ?? const [])) WorkoutMetric.fromJson(m as List)],
      laps: [
        for (final l in (j['laps'] as List? ?? const [])) Lap.fromJson(Map<String, dynamic>.from(l as Map))
      ],
      splits: [
        for (final s in (j['splits'] as List? ?? const []))
          Split.fromJson(Map<String, dynamic>.from(s as Map))
      ],
      lapStartMs: (j['lapStartMs'] as num?)?.toInt() ?? 0,
      lapStartDistanceM: (j['lapStartDistanceM'] as num?)?.toDouble() ?? 0,
      lapStartKcal: (j['lapStartKcal'] as num?)?.toDouble() ?? 0,
      splitStartMs: (j['splitStartMs'] as num?)?.toInt() ?? 0,
      goalReached: j['goalReached'] == true,
      autoPauseReason: j['autoPauseReason'] as String?,
      title: (j['title'] as String?) ?? 'Walk',
      note: (j['note'] as String?) ?? '',
      savedAt: dt('savedAt'),
    );
  }
}

/// Final figures shown after a walk. Derived from the session, never stored
/// separately, so it cannot disagree with what was recorded.
class WorkoutSummary {
  const WorkoutSummary({
    required this.session,
    required this.active,
    required this.paused,
    required this.total,
    required this.avgSpeed,
    required this.bestSplitMs,
    required this.avgCadence,
  });

  final WalkSession session;
  final Duration active;
  final Duration paused;
  final Duration total;

  /// m/s
  final double avgSpeed;
  final int? bestSplitMs;
  final int avgCadence;

  factory WorkoutSummary.of(WalkSession s, DateTime now) {
    final active = s.activeDuration(now);
    final secs = active.inMilliseconds / 1000;
    return WorkoutSummary(
      session: s,
      active: active,
      paused: s.pausedDuration(now),
      total: s.totalDuration(now),
      avgSpeed: secs <= 0 ? 0 : s.distanceM / secs,
      bestSplitMs: s.splits.isEmpty
          ? null
          : s.splits.map((x) => x.durationMs).reduce((a, b) => a < b ? a : b),
      avgCadence: secs <= 0 ? 0 : (s.steps / (secs / 60)).round(),
    );
  }

  bool get goalMet => !session.goal.isOpen && session.goalReached;
}

/// A saved walk (history). [syncStatus] is where cloud sync plugs in.
class WalkWorkout {
  const WalkWorkout({required this.session, this.syncStatus = 'local', this.deviceSource = 'phone'});
  final WalkSession session;
  final String syncStatus;
  final String deviceSource;

  Map<String, dynamic> toJson() =>
      {'session': session.toJson(), 'sync': syncStatus, 'device': deviceSource};
  factory WalkWorkout.fromJson(Map<String, dynamic> j) => WalkWorkout(
        session: WalkSession.fromJson(Map<String, dynamic>.from(j['session'] as Map)),
        syncStatus: (j['sync'] as String?) ?? 'local',
        deviceSource: (j['device'] as String?) ?? 'phone',
      );
}
