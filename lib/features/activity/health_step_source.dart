import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/time/local_day.dart';
import 'count_from.dart';
import 'movement_ledger.dart';
import 'movement_rules.dart';
import 'movement_tracker.dart';
import 'step_day.dart';
import 'step_source.dart';

/// Apple Health (iOS) and Health Connect (Android).
///
/// Manual entries are excluded everywhere (`includeManualEntry: false`) to
/// honour the "no manual step entry" rule at the source.
class HealthStepSource implements StepSource {
  HealthStepSource({
    Health? health,
    Future<MovementLedger> Function()? loadMovement,
    Future<DateTime?> Function()? countFrom,
  })  : _health = health ?? Health(),
        _loadMovement = loadMovement ?? loadMovementLedger,
        _countFrom = countFrom;

  /// When an organizer reset this profile's counts (see count_from.dart).
  final Future<DateTime?> Function()? _countFrom;

  final Health _health;

  /// GPS record of when the phone really travelled. Steps the health store
  /// logged while the phone stayed in one place (shaking) are removed.
  final Future<MovementLedger> Function() _loadMovement;
  bool _configured = false;

  static const _iosAskedKey = 'health_permission_requested';

  @override
  StepSourceKind get kind => StepSourceKind.healthStore;

  List<HealthDataType> get _extraTypes => Platform.isAndroid
      ? [
          HealthDataType.DISTANCE_DELTA,
          HealthDataType.ACTIVE_ENERGY_BURNED,
          HealthDataType.FLIGHTS_CLIMBED,
        ]
      : [
          HealthDataType.DISTANCE_WALKING_RUNNING,
          HealthDataType.ACTIVE_ENERGY_BURNED,
          HealthDataType.FLIGHTS_CLIMBED,
        ];

  // WORKOUT is requested so cycling / machine sessions can be excluded.
  List<HealthDataType> get _allTypes =>
      [HealthDataType.STEPS, ..._extraTypes, HealthDataType.WORKOUT];

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<SourceAvailability> availability() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return SourceAvailability.unsupported;
    }
    try {
      await _ensureConfigured();
      if (Platform.isAndroid) {
        final status = await _health.getHealthConnectSdkStatus();
        if (status != HealthConnectSdkStatus.sdkAvailable) {
          return SourceAvailability.needsHealthConnect;
        }
        final granted = await _health.hasPermissions(
          [HealthDataType.STEPS],
          permissions: [HealthDataAccess.READ],
        );
        return granted == true
            ? SourceAvailability.available
            : SourceAvailability.needsPermission;
      }
      // iOS never reveals whether READ access was granted (privacy), so we
      // remember that we asked. If the user declined, reads simply return
      // nothing and the sensor/zero state is shown.
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_iosAskedKey) == true
          ? SourceAvailability.available
          : SourceAvailability.needsPermission;
    } catch (e) {
      debugPrint('Health availability check failed: $e');
      return SourceAvailability.unsupported;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      await _ensureConfigured();
      final ok = await _health.requestAuthorization(
        _allTypes,
        permissions: List.filled(_allTypes.length, HealthDataAccess.READ),
      );
      if (Platform.isIOS) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_iosAskedKey, true);
        return true;
      }
      return ok;
    } catch (e) {
      debugPrint('Health permission request failed: $e');
      return false;
    }
  }

  Future<void> installHealthConnect() => _health.installHealthConnect();

  @override
  Future<List<StepDay>> readDays(List<DateTime> days, {required DateTime now}) async {
    await _ensureConfigured();
    MovementLedger? movement;
    try {
      movement = await _loadMovement();
    } catch (_) {} // no movement record: nothing extra is removed
    DateTime? countFrom;
    try {
      countFrom = await _countFrom?.call();
    } catch (_) {}
    final out = <StepDay>[];
    for (final day in days) {
      final dayStart = startOfDay(day);
      final nextMidnight = DateTime(day.year, day.month, day.day + 1);
      final end = nextMidnight.isAfter(now) ? now : nextMidnight;
      if (!end.isAfter(dayStart)) continue;

      // After a count reset, this day starts at the reset moment: the walker
      // begins again from zero and the earlier steps never come back.
      final cut = cutInside(dayStart, end, countFrom);
      final start = cut ?? dayStart;

      final read = await _health.getTotalStepsInInterval(
        start,
        end,
        includeManualEntry: false,
      );
      if ((read == null || read <= 0)) {
        if (cut == null) continue;
        // Reset day with nothing since the reset. Report 0 (so the old total
        // is replaced) ONLY if the health store has this day at all. If it
        // has no data, stay silent: a health total, even 0, overrides the
        // phone sensor and would freeze the count on sensor-only phones.
        final wholeDay = await _health.getTotalStepsInInterval(
          dayStart,
          end,
          includeManualEntry: false,
        );
        if (wholeDay == null || wholeDay <= 0) continue;
      }
      final total = read ?? 0;

      // Remove steps logged during cycling / exercise-machine sessions.
      final sessions = [
        ...await _excludedSessions(start, end),
        ..._stationarySpans(movement, start, end),
      ];
      final adjusted = await stepsExcludingSessions(
        total: total,
        sessions: sessions,
        window: TimeSpan(start, end),
        stepsBetween: (from, to) => _health.getTotalStepsInInterval(
          from,
          to,
          includeManualEntry: false,
        ),
      );
      if (adjusted.steps <= 0 && adjusted.excluded <= 0 && cut == null) continue;

      // Platform distance/energy would still include the bike ride, so they
      // are dropped when steps were removed; the sync service re-estimates
      // them from the steps that count.
      final extras = adjusted.excluded > 0 || cut != null
          ? (distanceM: null, kcal: null, floors: null)
          : await _readExtras(start, end);
      // Hourly breakdown for the last 3 days only (24 reads a day).
      final hours = startOfDay(now).difference(dayStart).inDays <= 2
          ? await _readHours(dayStart, end, sessions, adjusted.steps, from: cut)
          : null;
      out.add(StepDay.forDate(
        day,
        source: StepSourceKind.healthStore,
        hours: hours,
        countedFrom: cut,
        steps: adjusted.steps,
        distanceM: extras.distanceM,
        kcal: extras.kcal,
        floors: extras.floors,
        excludedSteps: adjusted.excluded,
      ));
    }
    return out;
  }

  /// Steps per hour for one day, with excluded sessions removed, scaled so
  /// they never add up to more than the day's valid total.
  Future<List<int>?> _readHours(
      DateTime start, DateTime end, List<TimeSpan> sessions, int dayTotal,
      {DateTime? from}) async {
    try {
      final hours = List<int>.filled(24, 0);
      for (var h = 0; h < 24; h++) {
        var hFrom = DateTime(start.year, start.month, start.day, h);
        if (!hFrom.isBefore(end)) break;
        var to = DateTime(start.year, start.month, start.day, h + 1);
        if (to.isAfter(end)) to = end;
        if (from != null) {
          if (!to.isAfter(from)) continue; // an hour wholly before the reset
          if (hFrom.isBefore(from)) hFrom = from;
        }
        final total = await _health.getTotalStepsInInterval(hFrom, to, includeManualEntry: false) ?? 0;
        if (total <= 0) continue;
        final adj = await stepsExcludingSessions(
          total: total,
          sessions: sessions,
          window: TimeSpan(hFrom, to),
          stepsBetween: (a, b) => _health.getTotalStepsInInterval(a, b, includeManualEntry: false),
        );
        hours[h] = adj.steps;
      }
      return fitHoursToTotal(hours, dayTotal);
    } catch (e) {
      debugPrint('Hourly steps unavailable: $e');
      return null;
    }
  }

  /// Times the GPS tracker saw the phone stay in one place. At most 80 of the
  /// longest are used, since each is a health-store query.
  List<TimeSpan> _stationarySpans(MovementLedger? m, DateTime start, DateTime end) {
    if (m == null) return const [];
    final spans = m.stationaryIn(TimeSpan(start, end));
    if (spans.length > 80) {
      spans.sort((a, b) => b.to.difference(b.from).compareTo(a.to.difference(a.from)));
      return spans.sublist(0, 80);
    }
    return spans;
  }

  /// Exercise sessions in the window whose steps must not count.
  /// If workout access was not granted this returns nothing (we cannot
  /// exclude what we cannot see); the Walk screen says so.
  Future<List<TimeSpan>> _excludedSessions(DateTime start, DateTime end) async {
    try {
      final points = await _health.getHealthDataFromTypes(
        types: [HealthDataType.WORKOUT],
        startTime: start,
        endTime: end,
      );
      return [
        for (final p in points)
          if (p.value is WorkoutHealthValue &&
              isExcludedWorkout(
                  (p.value as WorkoutHealthValue).workoutActivityType, p.metadata))
            TimeSpan(p.dateFrom, p.dateTo),
      ];
    } catch (e) {
      debugPrint('Workout sessions unavailable: $e');
      return const [];
    }
  }

  /// Distance, energy and floors are best-effort: a failure here must not
  /// lose the step count.
  Future<({int? distanceM, int? kcal, int? floors})> _readExtras(
      DateTime start, DateTime end) async {
    double? distance, energy, floors;
    try {
      final points = await _health.getHealthAggregateDataFromTypes(
        types: _extraTypes,
        startDate: start,
        endDate: end,
        activitySegmentDuration: 24 * 60,
        includeManualEntry: false,
      );
      for (final p in points) {
        final v = p.value;
        if (v is! NumericHealthValue) continue;
        final n = v.numericValue.toDouble();
        switch (p.type) {
          case HealthDataType.DISTANCE_DELTA:
          case HealthDataType.DISTANCE_WALKING_RUNNING:
            distance = (distance ?? 0) + n;
          case HealthDataType.ACTIVE_ENERGY_BURNED:
            energy = (energy ?? 0) + n;
          case HealthDataType.FLIGHTS_CLIMBED:
            floors = (floors ?? 0) + n;
          default:
            break;
        }
      }
    } catch (e) {
      debugPrint('Health extras unavailable: $e');
    }
    return (
      distanceM: distance?.round(),
      kcal: energy?.round(),
      floors: floors?.round(),
    );
  }
}
