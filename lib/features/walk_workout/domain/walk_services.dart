import 'walk_models.dart';

/// What the sensors report for one tick of a walk.
class TrackSample {
  const TrackSample({this.location, this.stepsDelta = 0, this.heartRate, this.speedHint});

  /// null = no GPS fix this tick (lost, off, or walking without GPS).
  final LocationPoint? location;

  /// Steps taken since the previous sample.
  final int stepsDelta;
  final int? heartRate;

  /// Speed from the sensor itself (m/s), when it provides one.
  final double? speedHint;
}

/// INTEGRATION POINT (real GPS): implement with geolocator (already in
/// pubspec) using a position stream; return the latest fix from [next].
abstract class LocationService {
  /// 'granted' | 'denied' | 'deniedForever' | 'serviceOff'
  Future<String> permissionStatus();
  Future<String> requestPermission();
  Future<void> start();
  Future<void> stop();

  /// Latest fix after [dt] of walking, or null when there is none.
  LocationPoint? next(Duration dt);
}

/// INTEGRATION POINT (pedometer): implement with StepCounterHub (this app's
/// single connection to the hardware step counter).
abstract class StepCounterService {
  Future<bool> available();
  Future<void> start();
  Future<void> stop();

  /// Steps since the previous call.
  int next(Duration dt);
}

/// INTEGRATION POINT (heart rate): Bluetooth HR strap, Wear OS / Apple
/// Watch companion, or the health platform's live heart-rate stream.
abstract class HeartRateService {
  Future<bool> available();
  Future<void> start();
  Future<void> stop();

  /// Current BPM, or null while measuring / no signal.
  int? next(Duration dt);
}

/// Feeds the session controller. One implementation combines the three
/// sensor services; tests script it directly.
abstract class WalkTrackingService {
  Future<void> start(WorkoutSettings settings);
  Future<void> stop();

  /// The reading for the last [dt]. Called once per tick while a walk is
  /// recording or auto-paused (to detect movement again).
  TrackSample advance(Duration dt);
}

/// INTEGRATION POINT (voice): flutter_tts or platform TTS.
abstract class VoiceCoachService {
  Future<void> say(String text);
}

/// INTEGRATION POINT (ongoing notification): Android foreground service
/// notification with Pause/Resume/Finish actions; iOS Live Activity.
abstract class NotificationService {
  /// Show or update the "Walk in progress" notification.
  Future<void> showOngoing({required String title, required String body});
  Future<void> clear();

  /// One-off milestone ("Goal reached").
  Future<void> milestone(String text);
}

/// INTEGRATION POINT (storage / backend): swap for a database plus cloud
/// sync. The active session MUST be stored locally for recovery.
abstract class WorkoutPersistenceService {
  Future<void> saveActive(WalkSession? session);
  Future<WalkSession?> loadActive();
  Future<void> saveWorkout(WalkWorkout workout);
  Future<List<WalkWorkout>> loadWorkouts();
  Future<void> deleteWorkout(String id);
}
