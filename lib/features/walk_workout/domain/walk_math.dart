import 'dart:math' as math;

import 'walk_models.dart';

/// Great-circle distance in metres.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Pace and speed arithmetic. Pure; all inputs in SI units.
class PaceCalculationService {
  const PaceCalculationService();

  static const double metresPerMile = 1609.344;

  double unitMetres(UnitSystem u) => u == UnitSystem.metric ? 1000 : metresPerMile;
  String distanceUnit(UnitSystem u) => u == UnitSystem.metric ? 'km' : 'mi';
  String speedUnit(UnitSystem u) => u == UnitSystem.metric ? 'km/h' : 'mph';
  String paceUnit(UnitSystem u) => u == UnitSystem.metric ? 'min/km' : 'min/mi';

  double distanceIn(UnitSystem u, double metres) => metres / unitMetres(u);
  double speedIn(UnitSystem u, double mps) => mps * 3600 / unitMetres(u);

  /// Seconds per km or mile; null below a crawl (not enough data to tell).
  int? paceSeconds(UnitSystem u, double mps) =>
      mps < 0.2 ? null : (unitMetres(u) / mps).round();

  /// Average speed (m/s) over [distanceM] and [active]; 0 when too short.
  double averageSpeed(double distanceM, Duration active) =>
      active.inSeconds < 5 || distanceM < 5 ? 0 : distanceM / (active.inMilliseconds / 1000);

  /// 'm:ss', or '--' when unknown.
  String formatPace(int? seconds) => seconds == null || seconds > 3600
      ? '--'
      : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  /// Stride-based distance for walking without GPS (0.414 x height).
  double strideMetres(double heightCm) => heightCm * 0.414 / 100;
}

/// Active-calorie estimate from walking speed (MET table), body weight and
/// time. INTEGRATION POINT: replace with the health platform's active
/// energy, or a heart-rate based model, when those are connected.
class CalorieCalculationService {
  const CalorieCalculationService();

  /// Metabolic equivalent for walking at [mps].
  double met(double mps) {
    final kmh = mps * 3.6;
    if (kmh < 1) return 1.3; // standing
    if (kmh < 3.2) return 2.0;
    if (kmh < 4.0) return 2.8;
    if (kmh < 4.8) return 3.0;
    if (kmh < 5.6) return 3.5;
    if (kmh < 6.4) return 4.3;
    if (kmh < 7.2) return 5.0;
    return 7.0;
  }

  /// kcal burned in [dt] at [mps]. Only the part above resting counts.
  double kcal({required double mps, required double weightKg, required Duration dt}) {
    final active = math.max(met(mps) - 1.0, 0.0);
    return active * weightKg * dt.inMilliseconds / 3600000.0;
  }
}

const List<String> kHeartRateZones = ['Rest', 'Warm-up', 'Fat burn', 'Cardio', 'Peak'];

/// 0 rest · 1 warm-up · 2 fat burn · 3 cardio · 4 peak.
int heartRateZone(int bpm, int maxHr) {
  final pct = bpm / maxHr;
  if (pct < 0.5) return 0;
  if (pct < 0.6) return 1;
  if (pct < 0.7) return 2;
  if (pct < 0.85) return 3;
  return 4;
}

/// Decides auto-pause / auto-resume from recent speeds. Pure and stateful
/// only through what it is fed, so it is easy to test.
class AutoPauseDetector {
  AutoPauseDetector({
    this.stillSpeed = 0.3,
    this.moveSpeed = 0.6,
    this.stillFor = const Duration(seconds: 10),
    this.moveFor = const Duration(seconds: 3),
  });

  final double stillSpeed;
  final double moveSpeed;
  final Duration stillFor;
  final Duration moveFor;

  Duration _still = Duration.zero;
  Duration _moving = Duration.zero;

  void reset() {
    _still = Duration.zero;
    _moving = Duration.zero;
  }

  /// Feed one reading while RECORDING. True when the walk should auto-pause.
  bool shouldPause(double mps, Duration dt) {
    _still = mps < stillSpeed ? _still + dt : Duration.zero;
    return _still >= stillFor;
  }

  /// Feed one reading while AUTO-PAUSED. True when it should resume.
  bool shouldResume(double mps, Duration dt) {
    _moving = mps > moveSpeed ? _moving + dt : Duration.zero;
    return _moving >= moveFor;
  }
}

String formatDuration(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two((s % 3600) ~/ 60)}:${two(s % 60)}';
}

/// Compact 'm:ss' (or 'h:mm:ss') for chips and banners.
String formatCompact(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final mm = ((s % 3600) ~/ 60), ss = (s % 60).toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${mm.toString().padLeft(2, '0')}:$ss' : '$mm:$ss';
}

/// Keeps long walks cheap to store: when [list] grows past [max], every
/// second older item is dropped (the newest quarter is kept intact).
List<T> thin<T>(List<T> list, int max) {
  if (list.length <= max) return list;
  final keepFrom = list.length - max ~/ 4;
  return [
    for (var i = 0; i < keepFrom; i += 2) list[i],
    ...list.sublist(keepFrom),
  ];
}

/// GPX 1.1 export of a route.
String toGpx(WalkSession s) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="Walkathon" xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('<trk><name>${s.title.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</name><trkseg>');
  for (final p in s.route) {
    final t = DateTime.fromMillisecondsSinceEpoch(p.tMs, isUtc: true).toIso8601String();
    b.writeln('<trkpt lat="${p.lat}" lon="${p.lon}">'
        '${p.altitude == null ? '' : '<ele>${p.altitude!.toStringAsFixed(1)}</ele>'}'
        '<time>$t</time></trkpt>');
  }
  b.writeln('</trkseg></trk></gpx>');
  return b.toString();
}
