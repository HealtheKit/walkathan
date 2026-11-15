import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/device_services.dart';
import '../data/mock_services.dart';
import '../domain/walk_math.dart';
import '../domain/walk_models.dart';
import '../domain/walk_services.dart';

// ---------------------------------------------------------------------
// Providers. Override these to plug in real sensors or to test.
// ---------------------------------------------------------------------

/// "Now". Overridden in tests so time can be moved by hand.
final walkClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// When false the controller does not start its own 1-second timer; tests
/// call [WalkSessionController.tick] themselves.
final walkAutoTickProvider = Provider<bool>((ref) => true);

/// THE SWITCH between simulated and real sensors. false (default): the
/// mock services invent a believable walk, so the feature runs anywhere.
/// true: GPS (geolocator) and the phone's step counter are used.
/// Override it at the ProviderScope, or change the default here.
final walkUseDeviceSensorsProvider = Provider<bool>((ref) => false);

/// INTEGRATION POINT: real GPS.
final locationServiceProvider = Provider<LocationService>((ref) =>
    ref.watch(walkUseDeviceSensorsProvider) ? GeolocatorLocationService() : MockLocationService());

/// INTEGRATION POINT: real pedometer.
final stepCounterServiceProvider = Provider<StepCounterService>((ref) =>
    ref.watch(walkUseDeviceSensorsProvider) ? HubStepCounterService() : MockStepCounterService());

/// INTEGRATION POINT: real heart-rate source.
final heartRateServiceProvider = Provider<HeartRateService>((ref) =>
    ref.watch(walkUseDeviceSensorsProvider) ? NoHeartRateService() : MockHeartRateService());

final walkTrackingServiceProvider = Provider<WalkTrackingService>((ref) =>
    SensorWalkTrackingService(
      location: ref.watch(locationServiceProvider),
      steps: ref.watch(stepCounterServiceProvider),
      heartRate: ref.watch(heartRateServiceProvider),
    ));

/// INTEGRATION POINT: text-to-speech.
final voiceCoachProvider = Provider<VoiceCoachService>((ref) => MockVoiceCoachService());

/// INTEGRATION POINT: ongoing system notification.
final walkNotificationProvider =
    Provider<NotificationService>((ref) => MockNotificationService());

/// INTEGRATION POINT: database / cloud.
final workoutPersistenceProvider =
    Provider<WorkoutPersistenceService>((ref) => PrefsWorkoutPersistence());

/// INTEGRATION POINT: the signed-in walker's real age / height / weight.
final walkUserProfileProvider = Provider<UserProfile>((ref) => const UserProfile());

const paceService = PaceCalculationService();
const calorieService = CalorieCalculationService();

enum StartResult { started, alreadyActive }

/// THE single source of truth for the walk. App-scoped (never autoDispose),
/// so the walk lives on while the user moves around the app.
///
/// State is `null` when there is no walk. Time is always derived from stored
/// timestamps (`activeMs` + `lastResumeAt`), so the timer is right after the
/// app has been in the background, and the 1-second tick only refreshes the
/// numbers on screen and pulls the next sensor sample.
class WalkSessionController extends Notifier<WalkSession?> {
  Timer? _timer;
  DateTime? _lastTick;
  final AutoPauseDetector _autoPause = AutoPauseDetector();
  LocationPoint? _lastPoint;
  int _sinceSeries = 0;
  int _sincePersist = 0;
  int _gpsMissing = 0;
  final List<int> _recentSteps = [];
  double _nextVoiceDistance = 0;
  int _nextVoiceSeconds = 0;
  Completer<void> _ready = Completer<void>();

  /// Completes when a stored walk (if any) has been restored.
  Future<void> get ready => _ready.future;

  /// True once restoring is done (so callers need not wait).
  bool get isReady => _ready.isCompleted;

  DateTime get _now => ref.read(walkClockProvider)();
  WalkTrackingService get _tracker => ref.read(walkTrackingServiceProvider);
  WorkoutPersistenceService get _store => ref.read(workoutPersistenceProvider);
  VoiceCoachService get _voice => ref.read(voiceCoachProvider);
  NotificationService get _notify => ref.read(walkNotificationProvider);

  /// A session older than this when the app comes back is not assumed to
  /// have kept walking: it is restored auto-paused instead.
  static const Duration recoveryGrace = Duration(minutes: 2);

  @override
  WalkSession? build() {
    ref.onDispose(() => _timer?.cancel());
    _ready = Completer<void>();
    Future<void>(_recover);
    return null;
  }

  // ------------------------------------------------------------ recovery

  Future<void> _recover() async {
    try {
      final stored = await _store.loadActive();
      if (stored == null || !stored.status.isLive) return;
      final now = _now;
      var s = stored.copyWith(recovered: true);
      switch (stored.status) {
        case WalkSessionStatus.preparing:
        case WalkSessionStatus.countingDown:
          // Never really started: nothing worth keeping.
          await _store.saveActive(null);
          return;
        case WalkSessionStatus.tracking:
        case WalkSessionStatus.gpsWeak:
          final gap = now.difference(stored.savedAt ?? stored.lastResumeAt ?? now);
          if (gap > recoveryGrace) {
            // The app was closed for a while. Bank the time up to the last
            // save and wait for the walker rather than inventing a walk.
            final banked = stored.activeMs +
                (stored.lastResumeAt == null || stored.savedAt == null
                    ? 0
                    : stored.savedAt!.difference(stored.lastResumeAt!).inMilliseconds.clamp(0, 1 << 40));
            s = s.copyWith(
              status: WalkSessionStatus.autoPaused,
              activeMs: banked,
              clearLastResumeAt: true,
              pausedAt: stored.savedAt ?? now,
              autoPauseReason: 'Paused because the app was closed',
              currentSpeed: 0,
            );
          }
        case WalkSessionStatus.saving:
          s = s.copyWith(status: WalkSessionStatus.awaitingSave);
        default:
          break;
      }
      state = s;
      if (s.status.isRecording || s.status == WalkSessionStatus.autoPaused) {
        await _tracker.start(s.settings);
      }
      _lastTick = now;
      _ensureTimer();
      _updateNotification();
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  // --------------------------------------------------------------- start

  /// Begins the 3-2-1 countdown. Refuses when a walk already exists, so two
  /// walks can never run at once.
  StartResult start({required WorkoutSettings settings, required WorkoutGoal goal}) {
    final cur = state;
    if (cur != null && cur.status.isLive) return StartResult.alreadyActive;
    final now = _now;
    state = WalkSession(
      id: 'walk-${now.microsecondsSinceEpoch}',
      status: WalkSessionStatus.countingDown,
      startedAt: now,
      settings: settings,
      goal: goal,
      countdown: 3,
    );
    _lastTick = now;
    _ensureTimer();
    _persist();
    return StartResult.started;
  }

  void skipCountdown() {
    if (state?.status == WalkSessionStatus.countingDown) _begin();
  }

  Future<void> _begin() async {
    final s = state;
    if (s == null) return;
    final now = _now;
    _autoPause.reset();
    _lastPoint = null;
    _recentSteps.clear();
    _gpsMissing = 0;
    _nextVoiceDistance = paceService.unitMetres(s.settings.units);
    _nextVoiceSeconds = 300;
    // The walk's clock starts NOW, not when the countdown began.
    state = WalkSession(
      id: s.id,
      status: WalkSessionStatus.tracking,
      startedAt: now,
      settings: s.settings,
      goal: s.goal,
      lastResumeAt: now,
    );
    _lastTick = now;
    try {
      await _tracker.start(s.settings);
    } catch (e) {
      state = state?.copyWith(status: WalkSessionStatus.error, errorMessage: 'Could not start the sensors.');
    }
    _say('Walk started.');
    _persist();
    _updateNotification();
  }

  void _ensureTimer() {
    if (!ref.read(walkAutoTickProvider)) return;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  // ---------------------------------------------------------------- tick

  /// One step of the session: countdown, or the next sensor sample. Runs
  /// every second; safe to call at any rate (it uses real elapsed time).
  void tick() {
    final s = state;
    if (s == null) return;
    final now = _now;
    final dt = now.difference(_lastTick ?? now);
    _lastTick = now;

    switch (s.status) {
      case WalkSessionStatus.countingDown:
        if (s.countdown <= 1) {
          _begin();
        } else {
          state = s.copyWith(countdown: s.countdown - 1);
        }
      case WalkSessionStatus.tracking:
      case WalkSessionStatus.gpsWeak:
        if (dt > Duration.zero) _record(s, now, dt);
      case WalkSessionStatus.autoPaused:
        if (dt > Duration.zero) _watchForMovement(s, dt);
      default:
        break;
    }
  }

  void _record(WalkSession s, DateTime now, Duration dt) {
    // After a long gap (app in the background) the sensors report the whole
    // gap in one sample; cap what a single tick may add.
    final step = dt > const Duration(seconds: 30) ? const Duration(seconds: 30) : dt;
    final sample = _tracker.advance(step);
    final secs = step.inMilliseconds / 1000;
    final profile = ref.read(walkUserProfileProvider);

    // ---- distance & speed
    var moved = 0.0;
    double? accuracy;
    var route = s.route;
    var elevGain = s.elevGain, elevLoss = s.elevLoss;
    double? altitude = s.altitude;
    final p = sample.location;
    if (p != null) {
      accuracy = p.accuracyM;
      _gpsMissing = 0;
      final prev = _lastPoint;
      if (prev != null) {
        final d = haversineM(prev.lat, prev.lon, p.lat, p.lon);
        // ignore jitter smaller than the fix can resolve, and teleports
        if (d >= 0.5 && d / secs < 8) moved = d;
        if (p.altitude != null && prev.altitude != null) {
          final dz = p.altitude! - prev.altitude!;
          if (dz > 0.3) elevGain += dz;
          if (dz < -0.3) elevLoss += -dz;
        }
      }
      _lastPoint = p;
      altitude = p.altitude ?? altitude;
      route = thin([...route, p], 3000);
    } else {
      _gpsMissing++;
      // No GPS: estimate from steps and stride length.
      moved = sample.stepsDelta * paceService.strideMetres(profile.heightCm);
    }
    final speed = sample.speedHint ?? (secs <= 0 ? 0.0 : moved / secs);

    // ---- steps & cadence (average over the last ~10 samples)
    _recentSteps.add(sample.stepsDelta);
    if (_recentSteps.length > 10) _recentSteps.removeAt(0);
    final cadence = (_recentSteps.fold<int>(0, (a, b) => a + b) /
            (_recentSteps.length * secs.clamp(0.2, 60)) *
            60)
        .round();

    // ---- heart rate
    final hr = sample.heartRate;
    var zoneMs = s.zoneMs;
    if (hr != null) {
      final z = heartRateZone(hr, profile.maxHeartRate);
      zoneMs = [for (var i = 0; i < 5; i++) s.zoneMs[i] + (i == z ? step.inMilliseconds : 0)];
    }

    final activeMs = s.activeDuration(now).inMilliseconds;
    final distance = s.distanceM + moved;

    // ---- kilometre splits
    var splits = s.splits;
    var splitStartMs = s.splitStartMs;
    while (distance >= (splits.length + 1) * 1000) {
      splits = [...splits, Split(index: splits.length + 1, durationMs: activeMs - splitStartMs)];
      splitStartMs = activeMs;
    }

    // ---- live chart point every 5 s of active time
    var series = s.series;
    _sinceSeries += step.inMilliseconds;
    if (_sinceSeries >= 5000) {
      _sinceSeries = 0;
      series = thin(
          [...series, WorkoutMetric(tSec: activeMs ~/ 1000, speed: speed, bpm: hr, altitude: altitude)],
          1500);
    }

    // ---- GPS quality
    final gpsWeak = s.settings.useGps && (_gpsMissing >= 5 || (accuracy != null && accuracy > 30));

    var next = s.copyWith(
      status: gpsWeak ? WalkSessionStatus.gpsWeak : WalkSessionStatus.tracking,
      distanceM: distance,
      steps: s.steps + sample.stepsDelta,
      kcal: s.kcal + calorieService.kcal(mps: speed, weightKg: profile.weightKg, dt: step),
      currentSpeed: speed,
      maxSpeed: speed > s.maxSpeed ? speed : s.maxSpeed,
      cadence: cadence,
      maxCadence: cadence > s.maxCadence ? cadence : s.maxCadence,
      currentHr: hr,
      clearHr: hr == null,
      maxHr: hr != null && hr > s.maxHr ? hr : s.maxHr,
      hrSum: s.hrSum + (hr ?? 0),
      hrCount: s.hrCount + (hr == null ? 0 : 1),
      zoneMs: zoneMs,
      elevGain: elevGain,
      elevLoss: elevLoss,
      altitude: altitude,
      gpsAccuracyM: accuracy,
      clearGps: accuracy == null,
      route: route,
      series: series,
      splits: splits,
      splitStartMs: splitStartMs,
    );

    // ---- goal
    if (!next.goal.isOpen && !next.goalReached && next.goalProgress(now) >= 1) {
      next = next.copyWith(goalReached: true);
      _say('Goal reached. Well done.');
      _notify.milestone('Goal reached');
    }
    state = next;

    // ---- voice coaching
    _coach(next, activeMs);

    // ---- auto-pause
    if (s.settings.autoPause && _autoPause.shouldPause(speed, step)) {
      _autoPauseNow('Auto-paused because movement stopped');
      return;
    }

    _sincePersist += step.inMilliseconds;
    if (_sincePersist >= 5000) {
      _sincePersist = 0;
      _persist();
      _updateNotification();
    }
  }

  void _coach(WalkSession s, int activeMs) {
    if (!s.settings.voiceCoaching) return;
    final u = s.settings.units;
    switch (s.settings.voiceInterval) {
      case VoiceInterval.everyUnit:
        if (s.distanceM >= _nextVoiceDistance) {
          final n = (_nextVoiceDistance / paceService.unitMetres(u)).round();
          _nextVoiceDistance += paceService.unitMetres(u);
          _say('$n ${u == UnitSystem.metric ? 'kilometre' : 'mile'}${n == 1 ? '' : 's'}. '
              'Time ${formatCompact(Duration(milliseconds: activeMs))}.');
        }
      case VoiceInterval.everyFiveMinutes:
        if (activeMs ~/ 1000 >= _nextVoiceSeconds) {
          _say('${_nextVoiceSeconds ~/ 60} minutes. '
              '${paceService.distanceIn(u, s.distanceM).toStringAsFixed(1)} ${paceService.distanceUnit(u)}.');
          _nextVoiceSeconds += 300;
        }
      case VoiceInterval.off:
        break;
    }
  }

  void _watchForMovement(WalkSession s, Duration dt) {
    // Only an auto-pause caused by standing still resumes by itself.
    if (s.recovered && s.autoPauseReason != 'Auto-paused because movement stopped') return;
    final step = dt > const Duration(seconds: 30) ? const Duration(seconds: 30) : dt;
    final sample = _tracker.advance(step);
    final secs = step.inMilliseconds / 1000;
    var speed = sample.speedHint ?? 0.0;
    final p = sample.location;
    if (sample.speedHint == null) {
      if (p != null && _lastPoint != null) {
        speed = haversineM(_lastPoint!.lat, _lastPoint!.lon, p.lat, p.lon) / secs;
      } else if (p == null) {
        speed = sample.stepsDelta *
            paceService.strideMetres(ref.read(walkUserProfileProvider).heightCm) /
            secs;
      }
    }
    if (p != null) _lastPoint = p;
    if (_autoPause.shouldResume(speed, step)) {
      _say('Resuming.');
      resume();
    }
  }

  // ------------------------------------------------------------ controls

  void pause() => _pause(WalkSessionStatus.paused, null);

  void _autoPauseNow(String reason) {
    _say('Auto-paused.');
    _pause(WalkSessionStatus.autoPaused, reason);
  }

  void _pause(WalkSessionStatus to, String? reason) {
    final s = state;
    if (s == null || !s.status.isRecording) return;
    final now = _now;
    state = s.copyWith(
      status: to,
      activeMs: s.activeDuration(now).inMilliseconds,
      clearLastResumeAt: true,
      pausedAt: now,
      currentSpeed: 0,
      autoPauseReason: reason,
      clearAutoPauseReason: reason == null,
    );
    _autoPause.reset();
    _persist();
    _updateNotification();
  }

  void resume() {
    final s = state;
    if (s == null || !s.status.isPaused) return;
    final now = _now;
    // A walk rebuilt from storage has no running sensors yet.
    final wasRecovered = s.recovered;
    state = s.copyWith(
      status: WalkSessionStatus.tracking,
      lastResumeAt: now,
      pausedMs: s.pausedDuration(now).inMilliseconds,
      clearPausedAt: true,
      clearAutoPauseReason: true,
      recovered: false,
    );
    _autoPause.reset();
    _lastPoint = null; // do not draw a straight line across the pause
    _lastTick = now;
    if (wasRecovered) _tracker.start(s.settings);
    _ensureTimer();
    _persist();
    _updateNotification();
  }

  /// Records a lap / checkpoint.
  void addLap() {
    final s = state;
    if (s == null || !s.status.isRecording) return;
    final activeMs = s.activeDuration(_now).inMilliseconds;
    state = s.copyWith(
      laps: [
        ...s.laps,
        Lap(
          index: s.laps.length + 1,
          durationMs: activeMs - s.lapStartMs,
          distanceM: s.distanceM - s.lapStartDistanceM,
          kcal: s.kcal - s.lapStartKcal,
        ),
      ],
      lapStartMs: activeMs,
      lapStartDistanceM: s.distanceM,
      lapStartKcal: s.kcal,
    );
    _persist();
  }

  void setUnits(UnitSystem units) {
    final s = state;
    if (s == null) return;
    // Display only: recorded data stays in metres.
    state = s.copyWith(settings: s.settings.copyWith(units: units));
    _persist();
  }

  /// Stops tracking and moves to "save or discard".
  Future<void> finish() async {
    final s = state;
    if (s == null ||
        !(s.status.isRecording || s.status.isPaused || s.status == WalkSessionStatus.error)) {
      return;
    }
    final now = _now;
    state = s.copyWith(
      status: WalkSessionStatus.saving,
      activeMs: s.activeDuration(now).inMilliseconds,
      clearLastResumeAt: true,
      pausedMs: s.pausedDuration(now).inMilliseconds,
      clearPausedAt: true,
      endedAt: now,
      currentSpeed: 0,
    );
    _stopTimer();
    try {
      await _tracker.stop();
    } catch (_) {}
    _say('Walk finished.');
    state = state?.copyWith(status: WalkSessionStatus.awaitingSave);
    await _persist();
    await _notify.clear();
  }

  /// Keeps the walk in history and ends the session (banner disappears).
  Future<void> save({String? title, String? note}) async {
    final s = state;
    if (s == null || s.status != WalkSessionStatus.awaitingSave) return;
    final done = s.copyWith(status: WalkSessionStatus.completed, title: title, note: note);
    try {
      await _store.saveWorkout(WalkWorkout(session: done));
      await _store.saveActive(null);
      state = null;
    } catch (e) {
      state = s.copyWith(errorMessage: 'Could not save. Try again.');
    }
  }

  /// Throws the walk away, at any stage.
  Future<void> discard() async {
    if (state == null) return;
    _stopTimer();
    try {
      await _tracker.stop();
    } catch (_) {}
    state = null;
    await _store.saveActive(null);
    await _notify.clear();
  }

  // ------------------------------------------------------------- helpers

  Future<void> _persist() async {
    final s = state;
    if (s == null) return;
    final stamped = s.copyWith(savedAt: _now);
    // the stored copy carries the save time; in-memory state keeps ticking
    try {
      await _store.saveActive(stamped);
    } catch (_) {
      // Storage full or unavailable: the walk carries on in memory.
    }
  }

  void _say(String text) {
    if (state?.settings.voiceCoaching ?? false) _voice.say(text);
  }

  void _updateNotification() {
    final s = state;
    if (s == null || !s.status.isLive || s.status == WalkSessionStatus.awaitingSave) return;
    final u = s.settings.units;
    _notify.showOngoing(
      title: switch (s.status) {
        WalkSessionStatus.paused => 'Walk paused',
        WalkSessionStatus.autoPaused => 'Walk auto-paused',
        _ => 'Walk in progress',
      },
      body: '${formatCompact(s.activeDuration(_now))} · '
          '${paceService.distanceIn(u, s.distanceM).toStringAsFixed(2)} ${paceService.distanceUnit(u)}',
    );
  }
}

final walkSessionProvider =
    NotifierProvider<WalkSessionController, WalkSession?>(WalkSessionController.new);

/// The status alone, so widgets that only care about it rebuild rarely.
final walkStatusProvider = Provider<WalkSessionStatus>(
    (ref) => ref.watch(walkSessionProvider.select((s) => s?.status)) ?? WalkSessionStatus.idle);

/// True while a walk must stay visible across the app.
final walkIsLiveProvider = Provider<bool>((ref) => ref.watch(walkStatusProvider).isLive);

/// Saved walks, newest first.
final walkHistoryProvider = FutureProvider.autoDispose<List<WalkWorkout>>(
    (ref) => ref.watch(workoutPersistenceProvider).loadWorkouts());
