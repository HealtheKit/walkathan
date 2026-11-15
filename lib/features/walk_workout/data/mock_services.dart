import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/walk_models.dart';
import '../domain/walk_services.dart';

// =====================================================================
// MOCK SENSORS. Every class here is a stand-in: it produces believable
// numbers so the whole feature runs with no hardware. Replace each one
// through the providers in application/walk_providers.dart.
// =====================================================================

/// MOCK GPS: walks a gentle loop at about 1.35 m/s with small speed changes.
/// REPLACE WITH: geolocator position stream (see LocationService).
class MockLocationService implements LocationService {
  MockLocationService({this.startLat = 29.3759, this.startLon = 47.9774, this.granted = true});

  final double startLat;
  final double startLon;
  bool granted;

  double _t = 0; // seconds walked
  double _dist = 0;
  int _clockMs = 0;

  @override
  Future<String> permissionStatus() async => granted ? 'granted' : 'denied';
  @override
  Future<String> requestPermission() async {
    granted = true;
    return 'granted';
  }

  @override
  Future<void> start() async {
    _t = 0;
    _dist = 0;
    _clockMs = DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<void> stop() async {}

  @override
  LocationPoint? next(Duration dt) {
    final s = dt.inMilliseconds / 1000;
    _t += s;
    _clockMs += dt.inMilliseconds;
    final speed = 1.35 + 0.25 * math.sin(_t / 40);
    _dist += speed * s;
    // a rounded loop about 600 m around
    const radius = 95.0;
    final a = _dist / radius;
    final north = radius * math.sin(a), east = radius * (1 - math.cos(a));
    return LocationPoint(
      lat: startLat + north / 111320,
      lon: startLon + east / (111320 * math.cos(startLat * math.pi / 180)),
      tMs: _clockMs,
      altitude: 12 + 4 * math.sin(_dist / 180),
      accuracyM: 4 + 2 * math.sin(_t / 17).abs(),
    );
  }
}

/// MOCK PEDOMETER: about 112 steps a minute.
/// REPLACE WITH: StepCounterHub.instance.counterStream deltas.
class MockStepCounterService implements StepCounterService {
  double _carry = 0;
  double _t = 0;

  @override
  Future<bool> available() async => true;
  @override
  Future<void> start() async {
    _carry = 0;
    _t = 0;
  }

  @override
  Future<void> stop() async {}

  @override
  int next(Duration dt) {
    final s = dt.inMilliseconds / 1000;
    _t += s;
    _carry += (1.87 + 0.1 * math.sin(_t / 30)) * s;
    final whole = _carry.floor();
    _carry -= whole;
    return whole;
  }
}

/// MOCK HEART RATE: warms up from 88 to about 118 bpm, then drifts.
/// REPLACE WITH: BLE heart-rate service / watch companion / health stream.
class MockHeartRateService implements HeartRateService {
  double _t = 0;

  @override
  Future<bool> available() async => true;
  @override
  Future<void> start() async => _t = 0;
  @override
  Future<void> stop() async {}

  @override
  int? next(Duration dt) {
    _t += dt.inMilliseconds / 1000;
    if (_t < 4) return null; // "Measuring…"
    final warm = 30 * (1 - math.exp(-_t / 90));
    return (88 + warm + 5 * math.sin(_t / 25)).round();
  }
}

/// Combines the three sensor services into one sample per tick. This class
/// is NOT a mock: give it real services and it is the real tracker.
class SensorWalkTrackingService implements WalkTrackingService {
  SensorWalkTrackingService({required this.location, required this.steps, required this.heartRate});

  final LocationService location;
  final StepCounterService steps;
  final HeartRateService heartRate;

  WorkoutSettings _settings = const WorkoutSettings();

  @override
  Future<void> start(WorkoutSettings settings) async {
    _settings = settings;
    if (settings.useGps) await location.start();
    await steps.start();
    if (settings.heartRate) await heartRate.start();
  }

  @override
  Future<void> stop() async {
    await location.stop();
    await steps.stop();
    await heartRate.stop();
  }

  @override
  TrackSample advance(Duration dt) => TrackSample(
        location: _settings.useGps ? location.next(dt) : null,
        stepsDelta: steps.next(dt),
        heartRate: _settings.heartRate ? heartRate.next(dt) : null,
      );
}

/// MOCK VOICE: remembers what it would have said (and logs in debug).
/// REPLACE WITH: flutter_tts.
class MockVoiceCoachService implements VoiceCoachService {
  final List<String> spoken = [];
  @override
  Future<void> say(String text) async {
    spoken.add(text);
    debugPrint('[voice coach] $text');
  }
}

/// MOCK NOTIFICATION: keeps the latest text so tests can assert the
/// notification stays in step with the in-app status.
/// REPLACE WITH: flutter_local_notifications + a foreground service.
class MockNotificationService implements NotificationService {
  String? ongoingTitle;
  String? ongoingBody;
  final List<String> milestones = [];

  @override
  Future<void> showOngoing({required String title, required String body}) async {
    ongoingTitle = title;
    ongoingBody = body;
  }

  @override
  Future<void> clear() async {
    ongoingTitle = null;
    ongoingBody = null;
  }

  @override
  Future<void> milestone(String text) async => milestones.add(text);
}

/// REAL local storage (SharedPreferences): the active session survives the
/// app being closed or the phone restarting. Saved walks are kept as a list.
/// INTEGRATION POINT: add cloud sync of [WalkWorkout] here.
class PrefsWorkoutPersistence implements WorkoutPersistenceService {
  static const _activeKey = 'walk_workout_active_v1';
  static const _historyKey = 'walk_workout_history_v1';
  static const int maxSaved = 200;

  @override
  Future<void> saveActive(WalkSession? session) async {
    final p = await SharedPreferences.getInstance();
    if (session == null) {
      await p.remove(_activeKey);
    } else {
      await p.setString(_activeKey, jsonEncode(session.toJson()));
    }
  }

  @override
  Future<WalkSession?> loadActive() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_activeKey);
    if (raw == null) return null;
    try {
      return WalkSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await p.remove(_activeKey); // corrupt: never block the app on it
      return null;
    }
  }

  @override
  Future<List<WalkWorkout>> loadWorkouts() async {
    final p = await SharedPreferences.getInstance();
    final out = <WalkWorkout>[];
    for (final raw in p.getStringList(_historyKey) ?? const <String>[]) {
      try {
        out.add(WalkWorkout.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<void> saveWorkout(WalkWorkout workout) async {
    final p = await SharedPreferences.getInstance();
    final list = [
      jsonEncode(workout.toJson()),
      ...(p.getStringList(_historyKey) ?? const <String>[]),
    ];
    await p.setStringList(_historyKey, list.take(maxSaved).toList());
  }

  @override
  Future<void> deleteWorkout(String id) async {
    final p = await SharedPreferences.getInstance();
    final kept = [
      for (final w in await loadWorkouts())
        if (w.session.id != id) jsonEncode(w.toJson()),
    ];
    await p.setStringList(_historyKey, kept);
  }
}

/// In-memory storage for tests.
class MemoryWorkoutPersistence implements WorkoutPersistenceService {
  WalkSession? active;
  final List<WalkWorkout> workouts = [];
  int activeWrites = 0;

  @override
  Future<void> saveActive(WalkSession? session) async {
    activeWrites++;
    // round-trip through JSON, exactly like real storage
    active = session == null
        ? null
        : WalkSession.fromJson(jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>);
  }

  @override
  Future<WalkSession?> loadActive() async => active;
  @override
  Future<void> saveWorkout(WalkWorkout workout) async => workouts.insert(0, workout);
  @override
  Future<List<WalkWorkout>> loadWorkouts() async => workouts;
  @override
  Future<void> deleteWorkout(String id) async =>
      workouts.removeWhere((w) => w.session.id == id);
}
