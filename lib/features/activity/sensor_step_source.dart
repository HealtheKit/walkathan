import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/time/local_day.dart';
import 'count_from.dart';
import 'movement_ledger.dart';
import 'movement_tracker.dart';
import 'sensor_delta_tracker.dart';
import 'step_counter_hub.dart';
import 'step_day.dart';
import 'step_source.dart';

/// The phone's hardware step counter (Android). The OS keeps counting while
/// the app is closed, and each read picks up the difference since the
/// previous read. Steps taken while GPS shows the phone stayed in one place
/// (shaking) are removed.
///
/// iOS does not use this: HealthKit already keeps history there.
class SensorStepSource implements StepSource {
  SensorStepSource({
    required this.profileId,
    Future<int?> Function()? readCounter,
    Future<MovementLedger> Function()? loadMovement,
    Future<DateTime?> Function()? countFrom,
  })  : _readCounter = readCounter ?? _platformCounter,
        _loadMovement = loadMovement ?? loadMovementLedger,
        _countFrom = countFrom;

  /// When an organizer reset this profile's counts (see count_from.dart).
  final Future<DateTime?> Function()? _countFrom;
  String get _cutKey => 'sensor_cut_$profileId';

  final String profileId;
  final Future<int?> Function() _readCounter;

  /// GPS record of when the phone really travelled (see [MovementLedger]).
  final Future<MovementLedger> Function() _loadMovement;

  String get _ledgerKey => 'sensor_ledger_$profileId';

  @override
  StepSourceKind get kind => StepSourceKind.phoneSensor;

  // Through the shared hub: opening a separate sensor stream here would
  // switch off the live counter on the Walk tab (see StepCounterHub).
  static Future<int?> _platformCounter() => StepCounterHub.instance.read();

  @override
  Future<SourceAvailability> availability() async {
    if (kIsWeb || !Platform.isAndroid) return SourceAvailability.unsupported;
    return (await Permission.activityRecognition.isGranted)
        ? SourceAvailability.available
        : SourceAvailability.needsPermission;
  }

  @override
  Future<bool> requestPermission() async {
    final ok = (await Permission.activityRecognition.request()).isGranted;
    if (ok) StepCounterHub.instance.restart();
    return ok;
  }

  @override
  Future<List<StepDay>> readDays(List<DateTime> days, {required DateTime now}) async {
    final counter = await _readCounter();
    final prefs = await SharedPreferences.getInstance();
    final tracker = SensorDeltaTracker(SensorLedger.decode(prefs.getString(_ledgerKey)));

    if (counter != null) {
      MovementLedger? movement;
      try {
        movement = await _loadMovement();
      } catch (_) {} // no movement record: count as before
      tracker.addReading(counter, now, stationaryShare: movement?.stationaryFraction);
      await prefs.setString(_ledgerKey, tracker.ledger.encode());
    }

    // A count reset: remember what the reset day held when this phone first
    // learned of it, and subtract that from then on.
    DateTime? countFrom;
    try {
      countFrom = await _countFrom?.call();
    } catch (_) {}
    SensorCut? cut;
    if (countFrom == null) {
      if (prefs.containsKey(_cutKey)) await prefs.remove(_cutKey);
    } else {
      cut = SensorCut.decode(prefs.getString(_cutKey));
      if (cut == null || !cut.countFrom.isAtSameMomentAs(countFrom)) {
        cut = SensorCut.snapshot(countFrom, dateKey(countFrom), tracker.hoursFor(countFrom));
        await prefs.setString(_cutKey, cut.encode());
      }
    }

    final out = <StepDay>[];
    for (final d in days) {
      if (cut != null && dateKey(d) == cut.date) {
        final hours = cut.apply(tracker.hoursFor(d));
        out.add(StepDay.forDate(d,
            source: StepSourceKind.phoneSensor,
            steps: hours.fold<int>(0, (a, b) => a + b),
            hours: hours,
            countedFrom: cut.countFrom));
        continue;
      }
      final steps = tracker.stepsFor(d);
      if (steps > 0) {
        out.add(StepDay.forDate(d,
            source: StepSourceKind.phoneSensor,
            steps: steps,
            hours: tracker.hoursFor(d)));
      }
    }
    return out;
  }
}
