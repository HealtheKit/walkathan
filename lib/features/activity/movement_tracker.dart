import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'movement_ledger.dart';

// v2: v1 records marked time without any GPS signal as "standing still"
// and must not be used.
// v3: v2 also treated confident Wi-Fi positions as proof of standing still.
const String kMovementLedgerKey = 'movement_ledger_v3';

/// Reads the movement record kept on this phone. Works in the background
/// isolate too: it reloads first because the app wrote it from another one.
Future<MovementLedger> loadMovementLedger([SharedPreferences? prefs]) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  try {
    await p.reload();
  } catch (_) {}
  return MovementLedger.decode(p.getString(kMovementLedgerKey));
}

enum MovementStatus {
  /// Not started, or this platform has no GPS (tests, web).
  off,

  /// Running: steps taken while standing still are ignored.
  active,

  /// The user has not allowed location (yet).
  needsPermission,

  /// The user refused for good; only system settings can change it.
  deniedForever,

  /// Location is switched off on the phone.
  serviceOff,
}

/// Runs the GPS only to learn WHEN the phone is travelling (see
/// [MovementLedger]). Positions never leave the phone and are not stored
/// beyond the last reference point.
///
/// The GPS reports every few seconds. A clear fix that does not move means
/// "standing still"; no clear fix (indoors, weak signal) means "unknown" and
/// removes nothing. On Android a foreground notification keeps it running
/// while the screen is off, which is required to catch shaking or walking
/// with the phone in a pocket.
class MovementTracker {
  MovementTracker._();
  static final MovementTracker instance = MovementTracker._();

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  final ValueNotifier<MovementStatus> status = ValueNotifier(MovementStatus.off);

  MovementLedger _ledger = MovementLedger();
  StreamSubscription<Position>? _sub;
  Timer? _beat;
  SharedPreferences? _prefs;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// True when the phone has been in one place for a while (and we are sure).
  bool isStationaryNow([DateTime? now]) =>
      status.value == MovementStatus.active && _ledger.stationaryAt(now ?? DateTime.now());

  /// Checks permission without asking.
  Future<MovementStatus> check() async {
    if (!supported) return MovementStatus.off;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return MovementStatus.serviceOff;
      final p = await Geolocator.checkPermission();
      return switch (p) {
        LocationPermission.always || LocationPermission.whileInUse => MovementStatus.active,
        LocationPermission.deniedForever => MovementStatus.deniedForever,
        _ => MovementStatus.needsPermission,
      };
    } catch (_) {
      return MovementStatus.off;
    }
  }

  /// Shows the system permission dialog when needed, then starts.
  Future<MovementStatus> requestAndStart() async {
    if (!supported) return MovementStatus.off;
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    } catch (_) {}
    return start();
  }

  /// Starts tracking when permission is already granted. Never prompts.
  Future<MovementStatus> start() async {
    final s = await check();
    if (s != MovementStatus.active) {
      await stop();
      status.value = s;
      return s;
    }
    if (_sub != null) {
      status.value = MovementStatus.active;
      return s;
    }
    _prefs ??= await SharedPreferences.getInstance();
    _ledger = await loadMovementLedger(_prefs);

    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            // Every few seconds, moving or not: a fix that does not move is
            // how standing still is told apart from having no signal.
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 5),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'Counting your walk',
              notificationText:
                  'Location stays on this phone. It only checks that you are moving.',
              notificationChannelName: 'Walk tracking',
              setOngoing: true,
            ),
          )
        : AppleSettings(
            accuracy: LocationAccuracy.high,
            activityType: ActivityType.fitness,
            distanceFilter: 0,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
            allowBackgroundLocationUpdates: true,
          );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object e) {
        debugPrint('Location stream error: $e');
        stop().then((_) => status.value = MovementStatus.serviceOff);
      },
    );
    // Only saves. It must NOT mark the tracker as "seeing": with no GPS
    // signal (indoors) that would make every step look like standing still.
    _beat = Timer.periodic(const Duration(seconds: 30), (_) => _save());
    status.value = MovementStatus.active;
    return MovementStatus.active;
  }

  void _onPosition(Position p) {
    _ledger.onFix(MovementFix(
      tMs: DateTime.now().millisecondsSinceEpoch,
      lat: p.latitude,
      lon: p.longitude,
      accuracyM: p.accuracy,
      // Use the chip's speed only when it reports a trustworthy one.
      speedMps: p.speed.isFinite && p.speed >= 0 && p.speedAccuracy <= 1.0 ? p.speed : null,
    ));
    if (DateTime.now().difference(_lastSave) > const Duration(seconds: 15)) _save();
  }

  Future<void> _save() async {
    _lastSave = DateTime.now();
    try {
      await _prefs?.setString(kMovementLedgerKey, _ledger.encode());
    } catch (_) {}
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _beat?.cancel();
    _beat = null;
    await _save();
  }

  Future<void> openSettings() async {
    try {
      if (status.value == MovementStatus.serviceOff) {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
    } catch (_) {}
  }
}
