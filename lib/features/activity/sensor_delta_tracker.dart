import 'dart:convert';

import '../../core/time/local_day.dart';

/// Turns the phone's cumulative step counter (steps since the last reboot,
/// as Android's TYPE_STEP_COUNTER reports) into per-local-day totals.
///
/// Pure logic: no platform calls, fully unit-tested. State is serialisable so
/// it survives app restarts and background runs.
///
/// Rules:
///  * First ever reading only sets the baseline; steps taken before we
///    started watching are unknown and are NOT invented.
///  * Counter went DOWN => the phone rebooted; every step in the new counter
///    happened after the previous reading.
///  * A gap that crosses midnight is split across the days in proportion to
///    time (an estimate; the server's rate check keeps it honest).
class SensorLedger {
  SensorLedger({
    this.lastCounter,
    this.lastReadAtMs,
    Map<String, int>? days,
    Map<String, int>? hours,
  })  : days = days ?? {},
        hours = hours ?? {};

  int? lastCounter;
  int? lastReadAtMs;

  /// Local day key -> steps counted by this phone.
  final Map<String, int> days;

  /// 'YYYY-MM-DD|H' -> steps in that local hour.
  final Map<String, int> hours;

  Map<String, dynamic> toJson() => {
        'lastCounter': lastCounter,
        'lastReadAtMs': lastReadAtMs,
        'days': days,
        'hours': hours,
      };

  String encode() => jsonEncode(toJson());

  factory SensorLedger.fromJson(Map<String, dynamic> j) => SensorLedger(
        lastCounter: (j['lastCounter'] as num?)?.toInt(),
        lastReadAtMs: (j['lastReadAtMs'] as num?)?.toInt(),
        days: {
          for (final e in ((j['days'] as Map?) ?? const {}).entries)
            e.key as String: (e.value as num).toInt(),
        },
        hours: {
          for (final e in ((j['hours'] as Map?) ?? const {}).entries)
            e.key as String: (e.value as num).toInt(),
        },
      );

  factory SensorLedger.decode(String? s) {
    if (s == null || s.isEmpty) return SensorLedger();
    try {
      return SensorLedger.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return SensorLedger(); // corrupt state: start clean rather than crash
    }
  }
}

class SensorDeltaTracker {
  SensorDeltaTracker(this.ledger, {this.keepDays = 40});

  final SensorLedger ledger;

  /// Old days are dropped so the stored state stays small.
  final int keepDays;

  /// Feed one cumulative counter reading taken at [now] (local time).
  /// Returns the number of steps newly attributed.
  ///
  /// [stationaryShare] gives, for the time between two readings, the share
  /// (0..1) during which the phone is KNOWN to have stayed in one place (GPS).
  /// That share of the new steps is dropped: they came from shaking, not
  /// walking. Unknown time is never dropped.
  int addReading(int counter, DateTime now,
      {double Function(DateTime from, DateTime to)? stationaryShare}) {
    final nowMs = now.millisecondsSinceEpoch;
    final lastC = ledger.lastCounter;
    final lastMs = ledger.lastReadAtMs;

    ledger.lastCounter = counter;
    ledger.lastReadAtMs = nowMs;

    if (lastC == null || lastMs == null) return 0; // baseline only
    if (nowMs <= lastMs) return 0; // clock went backwards: ignore the delta

    final raw = counter >= lastC ? counter - lastC : counter; // reboot
    if (raw <= 0) return 0;

    final from = DateTime.fromMillisecondsSinceEpoch(lastMs);
    final still = stationaryShare?.call(from, now) ?? 0;
    final delta = still <= 0 ? raw : (raw * (1 - still.clamp(0.0, 1.0))).round();
    if (delta <= 0) return 0;

    _attribute(delta, from, now);
    _prune(now);
    return delta;
  }

  /// Splits [delta] over the local HOURS between [from] and [to] by time;
  /// day totals are the sum of their hours.
  void _attribute(int delta, DateTime from, DateTime to) {
    final totalMs = to.difference(from).inMilliseconds;
    var assigned = 0;
    var cursor = from;
    while (cursor.isBefore(to)) {
      var next = DateTime(cursor.year, cursor.month, cursor.day, cursor.hour + 1);
      final last = !next.isBefore(to);
      if (last) next = to;
      final part = last
          ? delta - assigned
          : (delta * next.difference(cursor).inMilliseconds / totalMs).round();
      if (part > 0) {
        _add(dateKey(cursor), part);
        final hk = '${dateKey(cursor)}|${cursor.hour}';
        ledger.hours[hk] = (ledger.hours[hk] ?? 0) + part;
      }
      assigned += part;
      cursor = next;
    }
  }

  void _add(String key, int steps) {
    if (steps <= 0) return;
    ledger.days[key] = (ledger.days[key] ?? 0) + steps;
  }

  void _prune(DateTime now) {
    final oldest = dateKey(daysAgo(now, keepDays));
    ledger.days.removeWhere((k, _) => k.compareTo(oldest) < 0);
    ledger.hours.removeWhere((k, _) => k.compareTo(oldest) < 0);
  }

  int stepsFor(DateTime day) => ledger.days[dateKey(day)] ?? 0;

  /// The day's 24 hourly values, or null when nothing was counted.
  List<int>? hoursFor(DateTime day) {
    final k = dateKey(day);
    if ((ledger.days[k] ?? 0) == 0) return null;
    return [for (var h = 0; h < 24; h++) ledger.hours['$k|$h'] ?? 0];
  }
}
