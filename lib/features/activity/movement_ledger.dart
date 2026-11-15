import 'dart:convert';
import 'dart:math' as math;

import 'movement_rules.dart' show TimeSpan;

/// One GPS reading.
class MovementFix {
  const MovementFix({
    required this.tMs,
    required this.lat,
    required this.lon,
    required this.accuracyM,
    this.speedMps,
  });

  final int tMs;
  final double lat;
  final double lon;
  final double accuracyM;

  /// Speed measured by the GPS chip itself (not from positions), or null
  /// when the fix has none (Wi-Fi / cell positions never do).
  final double? speedMps;
}

/// Great-circle distance in metres.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Records WHEN the phone was really travelling, so steps counted while it
/// stayed in one place (for example the phone being shaken) can be removed.
///
/// Pure logic, no platform calls. Everything is kept on the phone: only
/// time spans (plus the one last position needed to measure the next move)
/// are stored, and nothing here is ever uploaded.
///
/// Two kinds of span are kept:
///  * `alive`:  the GPS had a GOOD fix, so no displacement means "not moving".
///  * `moving`: the phone travelled; steps in these spans count.
///
/// Time with no `alive` coverage is UNKNOWN (tracker off, permission denied,
/// no signal) and is never penalised: we only remove steps we can positively
/// say happened while standing still.
class MovementLedger {
  MovementLedger({
    List<TimeSpan>? moving,
    List<TimeSpan>? alive,
    this.anchor,
  })  : moving = moving ?? [],
        alive = alive ?? [];

  /// Smallest displacement that can count as travel. GPS drifts by several
  /// metres even when the phone is on a table.
  static const double minMoveM = 12;

  /// Slowest and fastest believable speeds for a walk or run (m/s). Slower
  /// is GPS drift; faster is a vehicle.
  static const double minSpeed = 0.5;
  static const double maxSpeed = 12;

  /// Fixes less accurate than this are ignored completely: they prove
  /// neither movement nor standing still. Time with only such fixes is
  /// UNKNOWN, so no steps are removed for it.
  static const double maxAccuracyM = 20;

  /// Only a satellite-grade fix can prove STANDING STILL. Indoors a phone
  /// often reports a confident-looking position from Wi-Fi (about 15-40 m)
  /// that does not move while the person walks around the room; treating
  /// that as "not moving" stopped the count for real indoor walking.
  static const double clearAccuracyM = 10;

  /// GPS-chip speed from which the person is taken to be walking, even when
  /// they have not yet travelled [minMoveM] (pacing in a small area).
  static const double minChipSpeed = 0.7;

  /// No new movement for this long means the person has stopped. Short
  /// pauses (a road crossing) are covered by the span extended to each fix.
  static const Duration maxGap = Duration(seconds: 45);

  /// Good fixes this close together belong to one stretch of clear signal.
  /// Fixes arrive every few seconds, so a longer silence means it was lost.
  static const Duration aliveGap = Duration(seconds: 40);

  /// Spans older than this are dropped.
  static const int keepDays = 35;

  final List<TimeSpan> moving;
  final List<TimeSpan> alive;

  /// Last position used as the reference for the next displacement.
  MovementFix? anchor;

  /// Time of the previous usable fix (not persisted; only joins speed spans).
  int? _lastFixMs;

  // --------------------------------------------------------------- input

  /// The GPS can see the phone clearly at [now]. Called for every good fix;
  /// never on a timer, because a running tracker with no signal knows nothing.
  void heartbeat(DateTime now) {
    _extend(alive, now, now, aliveGap);
    _prune(now);
  }

  /// Feed one GPS reading.
  void onFix(MovementFix f) {
    if (f.accuracyM > maxAccuracyM) return; // no usable signal: unknown
    final at = DateTime.fromMillisecondsSinceEpoch(f.tMs);
    // Only a satellite-grade fix lets us say "the phone is not moving".
    if (f.accuracyM <= clearAccuracyM) {
      heartbeat(at);
    } else {
      _prune(at);
    }

    // The GPS chip measures speed directly: walking shows up at once, even
    // in a small area, and shaking a phone on the spot does not.
    final prevMs = _lastFixMs;
    _lastFixMs = f.tMs;
    final v = f.speedMps;
    if (v != null && v >= minChipSpeed && v <= maxSpeed) {
      final fromMs = prevMs != null && f.tMs - prevMs <= maxGap.inMilliseconds && prevMs < f.tMs
          ? prevMs
          : f.tMs - 5000;
      _extend(moving, DateTime.fromMillisecondsSinceEpoch(fromMs), at, maxGap);
    }

    final a = anchor;
    if (a == null || f.tMs <= a.tMs) {
      anchor = f;
      return;
    }
    final dtMs = f.tMs - a.tMs;
    if (dtMs > maxGap.inMilliseconds) {
      // Long silence: the person was standing still. Restart the reference
      // here, without crediting anything.
      anchor = f;
      return;
    }
    final d = distanceMeters(a.lat, a.lon, f.lat, f.lon);
    final needed = math.max(minMoveM, (a.accuracyM + f.accuracyM) / 2);
    if (d < needed) return; // not (yet) a real move; keep the old reference

    final speed = d / (dtMs / 1000);
    anchor = f;
    if (speed < minSpeed || speed > maxSpeed) return;
    _extend(moving, DateTime.fromMillisecondsSinceEpoch(a.tMs), at, maxGap);
  }

  static void _extend(List<TimeSpan> spans, DateTime from, DateTime to, Duration join) {
    if (spans.isNotEmpty && !from.isAfter(spans.last.to.add(join))) {
      final last = spans.removeLast();
      spans.add(TimeSpan(
          last.from.isBefore(from) ? last.from : from, to.isAfter(last.to) ? to : last.to));
    } else {
      spans.add(TimeSpan(from, to));
    }
  }

  void _prune(DateTime now) {
    final oldest = now.subtract(const Duration(days: keepDays));
    alive.removeWhere((s) => s.to.isBefore(oldest));
    moving.removeWhere((s) => s.to.isBefore(oldest));
  }

  // -------------------------------------------------------------- output

  /// Parts of [window] where the tracker was running but the phone did NOT
  /// travel. Spans shorter than [minLength] are left out (nothing worth
  /// removing, and each one costs a health-store query).
  List<TimeSpan> stationaryIn(TimeSpan window,
      {Duration minLength = const Duration(seconds: 30)}) {
    final out = <TimeSpan>[];
    for (final a in alive) {
      var from = a.from.isBefore(window.from) ? window.from : a.from;
      final to = a.to.isAfter(window.to) ? window.to : a.to;
      if (!to.isAfter(from)) continue;
      // Walk through the moving spans that overlap this alive span.
      for (final m in moving) {
        if (!m.to.isAfter(from)) continue;
        if (!m.from.isBefore(to)) break;
        if (m.from.isAfter(from)) out.add(TimeSpan(from, m.from));
        if (m.to.isAfter(from)) from = m.to;
        if (!from.isBefore(to)) break;
      }
      if (to.isAfter(from)) out.add(TimeSpan(from, to));
    }
    return out.where((s) => s.to.difference(s.from) >= minLength).toList();
  }

  /// Share (0..1) of [from]..[to] known to be stationary. Unknown time counts
  /// as moving, so this never removes more than the evidence supports.
  double stationaryFraction(DateTime from, DateTime to) {
    final total = to.difference(from).inMilliseconds;
    if (total <= 0) return 0;
    var still = 0;
    for (final s in stationaryIn(TimeSpan(from, to), minLength: Duration.zero)) {
      still += s.to.difference(s.from).inMilliseconds;
    }
    return (still / total).clamp(0.0, 1.0);
  }

  /// True when the tracker has been running long enough to know and the phone
  /// has not travelled recently. False when unsure.
  bool stationaryAt(DateTime now) {
    if (alive.isEmpty) return false;
    final run = alive.last;
    if (now.difference(run.to) > aliveGap) return false; // tracker not running
    if (now.difference(run.from) < maxGap) return false; // just started: unsure
    if (moving.isNotEmpty && now.difference(moving.last.to) <= maxGap) return false;
    return true;
  }

  // --------------------------------------------------------- persistence

  Map<String, dynamic> toJson() => {
        'moving': [for (final s in moving) [s.from.millisecondsSinceEpoch, s.to.millisecondsSinceEpoch]],
        'alive': [for (final s in alive) [s.from.millisecondsSinceEpoch, s.to.millisecondsSinceEpoch]],
        if (anchor != null)
          'anchor': [anchor!.tMs, anchor!.lat, anchor!.lon, anchor!.accuracyM],
      };

  String encode() => jsonEncode(toJson());

  static List<TimeSpan> _spans(Object? v) => [
        for (final e in (v as List? ?? const []))
          TimeSpan(DateTime.fromMillisecondsSinceEpoch((e as List)[0] as int),
              DateTime.fromMillisecondsSinceEpoch(e[1] as int)),
      ];

  factory MovementLedger.decode(String? s) {
    if (s == null || s.isEmpty) return MovementLedger();
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final an = j['anchor'] as List?;
      return MovementLedger(
        moving: _spans(j['moving']),
        alive: _spans(j['alive']),
        anchor: an == null
            ? null
            : MovementFix(
                tMs: (an[0] as num).toInt(),
                lat: (an[1] as num).toDouble(),
                lon: (an[2] as num).toDouble(),
                accuracyM: (an[3] as num).toDouble()),
      );
    } catch (_) {
      return MovementLedger(); // corrupt: start clean rather than crash
    }
  }
}
