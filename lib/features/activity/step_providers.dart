import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/firebase_constants.dart';
import '../../providers/profile_providers.dart';
import '../../repositories/step_repository.dart';
import '../../core/time/local_day.dart';
import 'count_from.dart';
import 'health_step_source.dart';
import 'history_math.dart';
import 'live_overlay.dart';
import 'movement_tracker.dart';
import 'sensor_step_source.dart';
import 'step_counter_hub.dart';
import 'step_day.dart';
import 'step_queue.dart';
import 'step_source.dart';
import 'step_sync_service.dart';

final stepRepositoryProvider = Provider<StepRepository>((ref) => StepRepository());

const _deviceChannel = MethodChannel('walkathon/device');

/// Stable id for THIS phone, used by the server to bind the phone to one
/// profile. Prefers the hardware-scoped id from the platform (survives an
/// app reinstall), falling back to a random id. The result is cached so the
/// background task, which has no platform channel, uses the same value.
Future<String> loadDeviceId(SharedPreferences prefs) async {
  final cached = prefs.getString('device_id_v2');
  if (cached != null && cached.length >= 8) return cached;

  String? id;
  try {
    final hw = await _deviceChannel.invokeMethod<String>('getId');
    if (hw != null && hw.trim().length >= 8) id = 'hw-${hw.trim()}';
  } catch (_) {
    // No channel (tests, background isolate, unsupported platform).
  }
  if (id == null) {
    final r = Random.secure();
    id = 'rnd-${List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join()}';
  }
  if (id.length > 64) id = id.substring(0, 64);
  await prefs.setString('device_id_v2', id);
  return id;
}

/// Real-time cumulative step counter (null where unavailable). Override in
/// tests.
final liveCounterProvider = Provider<Stream<int>?>((ref) {
  if (!StepCounterHub.supported) return null;
  return StepCounterHub.instance.counterStream;
});

/// One event per detected step (Android), so the Walk tab moves with every
/// step instead of waiting for the counter's next batch. Override in tests.
final liveStepDetectorProvider = Provider<Stream<void>?>((ref) {
  if (!StepCounterHub.supported) return null;
  return StepCounterHub.instance.stepStream;
});

/// True while GPS shows this phone standing still (so shaken steps are not
/// shown). False when unsure or when GPS is off. Override in tests.
final stationaryGateProvider = Provider<bool Function()>((ref) {
  return () => MovementTracker.instance.isStationaryNow();
});

/// Which sources to read. Override in tests.
final stepSourcesProvider = Provider.family<List<StepSource>, String>((ref, profileId) {
  if (kIsWeb) return const [];
  return [
    HealthStepSource(countFrom: () => loadCountFrom(profileId)),
    if (Platform.isAndroid)
      SensorStepSource(profileId: profileId, countFrom: () => loadCountFrom(profileId)),
  ];
});

class StepTrackingState {
  const StepTrackingState({
    this.today,
    this.sources = const {},
    this.pending = 0,
    this.lastSync,
    this.error,
    this.syncing = false,
    this.profileId,
    this.liveExtra = 0,
    this.live = false,
    this.otherOwnerName,
    this.otherOwnerProfileId,
    this.canMoveDevice = false,
    this.foreignDevice = false,
    this.pausedNotMoving = false,
  });

  final StepDay? today;
  final Map<StepSourceKind, SourceAvailability> sources;
  final int pending;
  final DateTime? lastSync;
  final String? error;
  final bool syncing;
  final String? profileId;

  /// Steps counted live since the last sync (display only).
  final int liveExtra;

  /// True while the real-time counter is feeding the display.
  final bool live;

  /// True while the phone's steps are being ignored because GPS shows it is
  /// not moving. Shown on the Walk screen so a stopped count is explained.
  final bool pausedNotMoving;

  /// Set when THIS PHONE counts steps for a different profile of the
  /// household. The active profile's steps then come from their own phone
  /// and are shown read-only.
  final String? otherOwnerName;
  final String? otherOwnerProfileId;
  final bool canMoveDevice;

  /// The phone is bound to a profile in another household.
  final bool foreignDevice;

  /// This phone is not the active profile's phone.
  bool get readOnly => otherOwnerProfileId != null || foreignDevice;

  /// The number to show: synced total plus live steps.
  int get displaySteps => (today?.steps ?? 0) + (readOnly ? 0 : liveExtra);

  bool get needsHealthConnect =>
      sources[StepSourceKind.healthStore] == SourceAvailability.needsHealthConnect;

  /// True when nothing can currently read steps and permission would fix it.
  bool get needsPermission =>
      sources.isNotEmpty &&
      !sources.values.any((s) => s == SourceAvailability.available) &&
      sources.values.any((s) => s == SourceAvailability.needsPermission);

  bool get unsupported =>
      sources.isNotEmpty &&
      sources.values.every((s) => s == SourceAvailability.unsupported);

  StepTrackingState copyWith({
    StepDay? today,
    Map<StepSourceKind, SourceAvailability>? sources,
    int? pending,
    DateTime? lastSync,
    String? error,
    bool clearError = false,
    bool? syncing,
    int? liveExtra,
    bool? live,
    bool? pausedNotMoving,
  }) =>
      StepTrackingState(
        today: today ?? this.today,
        sources: sources ?? this.sources,
        pending: pending ?? this.pending,
        lastSync: lastSync ?? this.lastSync,
        error: clearError ? null : (error ?? this.error),
        syncing: syncing ?? this.syncing,
        profileId: profileId,
        liveExtra: liveExtra ?? this.liveExtra,
        live: live ?? this.live,
        pausedNotMoving: pausedNotMoving ?? this.pausedNotMoving,
        otherOwnerName: otherOwnerName,
        otherOwnerProfileId: otherOwnerProfileId,
        canMoveDevice: canMoveDevice,
        foreignDevice: foreignDevice,
      );
}

/// Drives step reading and syncing for the ACTIVE profile.
///
/// Each profile has its own count: a phone is bound to one profile, and only
/// that profile's steps are read from it. Other profiles see their own
/// (server) numbers read-only on this phone.
class StepTrackingController extends AsyncNotifier<StepTrackingState> {
  final LiveStepOverlay _overlay = LiveStepOverlay();
  StreamSubscription<int>? _liveSub;
  StreamSubscription<void>? _detectorSub;
  DateTime? _lastAutoSync;

  /// While walking, sync at most this often.
  static const Duration liveSyncInterval = Duration(seconds: 20);

  @override
  Future<StepTrackingState> build() async {
    ref.onDispose(_stopLive);
    final profile = await ref.watch(activeProfileProvider.future);
    if (profile == null) return const StepTrackingState();

    final prefs = await SharedPreferences.getInstance();
    final cached = _readCache(prefs, profile.id);
    final initial = StepTrackingState(today: cached, profileId: profile.id);

    // Show cached numbers immediately. The first sync must run AFTER this
    // build has published its state (a microtask would run too early and
    // silently do nothing, leaving the screen stale until a manual refresh).
    Future<void>(() => refresh());
    return initial;
  }

  StepDay? _readCache(SharedPreferences prefs, String profileId) {
    final raw = prefs.getString('today_cache_$profileId');
    if (raw == null) return null;
    try {
      final d = StepDay.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // A cached total is only valid for the day it was taken.
      return d.localDate == dateKey(DateTime.now()) ? d : null;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- live

  void _startLive() {
    // GPS only learns whether the phone is travelling; permission is asked
    // from the Walk screen, never here.
    MovementTracker.instance.start();
    if (_liveSub != null) return;
    final stream = ref.read(liveCounterProvider);
    if (stream == null) return;
    _liveSub = stream.listen(_onCounter, onError: (_) {
      // No sensor or permission: the display simply stays on synced totals.
    });
    _detectorSub = ref.read(liveStepDetectorProvider)?.listen((_) => _onDetectedStep(),
        onError: (_) {});
  }

  void _stopLive() {
    _liveSub?.cancel();
    _liveSub = null;
    _detectorSub?.cancel();
    _detectorSub = null;
    _overlay.reset();
  }

  void _publishLive(int extra, {bool paused = false}) {
    final cur = state.value;
    if (cur == null) return;
    if (extra != cur.liveExtra || !cur.live || paused != cur.pausedNotMoving) {
      state = AsyncData(
          cur.copyWith(liveExtra: extra, live: true, pausedNotMoving: paused));
    }
  }

  void _onDetectedStep() {
    final cur = state.value;
    if (cur == null || cur.readOnly) return;
    if (ref.read(stationaryGateProvider)()) {
      _publishLive(cur.liveExtra, paused: true); // not moving: say so
      return;
    }
    _publishLive(_overlay.onDetectedStep());
  }

  void _onCounter(int counter) {
    final cur = state.value;
    if (cur == null || cur.readOnly) return;
    final still = ref.read(stationaryGateProvider)();
    final extra = _overlay.onCounter(counter, countable: !still);
    _publishLive(extra, paused: still);
    // While steps are arriving, push them to the server regularly so other
    // people's boards stay current too.
    final now = DateTime.now();
    if (extra > 0 &&
        (_lastAutoSync == null || now.difference(_lastAutoSync!) >= liveSyncInterval)) {
      _lastAutoSync = now;
      refresh();
    }
  }

  // ------------------------------------------------------------- sync

  Future<void> refresh() async {
    final current = state.value;
    if (current == null || current.syncing) return;
    final profile = await ref.read(activeProfileProvider.future);
    if (profile == null) return;

    state = AsyncData(current.copyWith(syncing: true, clearError: true));
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = await loadDeviceId(prefs);
      final repo = ref.read(stepRepositoryProvider);

      // Whose phone is this? (Cached so it also works offline.)
      final claim = await _claim(prefs, repo, deviceId, profile.id);
      if (!claim.mine) {
        _stopLive();
        state = AsyncData(await _readOnlyState(repo, profile.id, claim, current));
        return;
      }

      // Did an organizer set this profile to zero? The step sources then
      // count from that moment. Offline: the last known value is kept.
      try {
        await saveCountFrom(prefs, profile.id, await repo.fetchCountFrom(profile.id));
      } catch (_) {}

      final firstRun = prefs.getBool('backfilled_${profile.id}') != true;
      // Staff asked for a re-sync: upload the last month again.
      final resyncKey = 'resync_done_${profile.id}';
      final resyncAt = profile.resyncRequestedAt;
      final resync = resyncAt != null &&
          resyncAt.isAfter(DateTime.tryParse(prefs.getString(resyncKey) ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0));
      final service = StepSyncService(
        sources: ref.read(stepSourcesProvider(profile.id)),
        queue: StepQueue(prefs, profile.id),
        uploader: repo,
        profileId: profile.id,
        deviceId: deviceId,
        heightCm: profile.heightCm,
        weightKg: profile.weightKg,
      );
      final result = await service.sync(backfillDays: firstRun || resync ? 30 : 3);
      if (resync && result.error == null) {
        await prefs.setString(resyncKey, resyncAt.toIso8601String());
      }

      if (result.today != null) {
        await prefs.setString('today_cache_${profile.id}', jsonEncode(result.today!.toJson()));
      }
      if (firstRun && result.sourceStatus.values.any((s) => s == SourceAvailability.available)) {
        await prefs.setBool('backfilled_${profile.id}', true);
      }
      await _rememberForBackground(prefs, profile.id, profile.heightCm, profile.weightKg);

      final oldTotal = current.today?.steps ?? 0;
      final today = result.today ?? current.today;
      _overlay.onSynced(oldTotal: oldTotal, newTotal: today?.steps ?? 0);

      state = AsyncData(StepTrackingState(
        today: today,
        sources: result.sourceStatus,
        pending: result.pending,
        lastSync: DateTime.now(),
        error: result.error,
        profileId: profile.id,
        liveExtra: _overlay.extra,
        live: _liveSub != null && (state.value?.live ?? false),
      ));
      _startLive();
    } catch (e) {
      state = AsyncData(
          (state.value ?? current).copyWith(syncing: false, error: e.toString()));
      // A failed sync (offline, server down) must not stop live counting.
      if (!(state.value?.readOnly ?? true)) _startLive();
    }
  }

  Future<DeviceClaim> _claim(SharedPreferences prefs, StepRepository repo,
      String deviceId, String profileId) async {
    try {
      final c = await repo.claimDevice(deviceId, profileId);
      await prefs.setString(
          'device_owner',
          jsonEncode({
            'mine_for': c.mine ? profileId : null,
            'owner': c.ownerProfileId,
            'name': c.ownerName,
          }));
      return c;
    } catch (_) {
      // Offline: fall back to what we last knew. Unknown = assume ours; the
      // server still refuses uploads if that turns out to be wrong.
      try {
        final m = jsonDecode(prefs.getString('device_owner') ?? '{}') as Map;
        final owner = m['owner'] as String?;
        if (owner != null && owner != profileId) {
          return DeviceClaim(
              mine: false, ownerProfileId: owner, ownerName: m['name'] as String?);
        }
      } catch (_) {}
      return const DeviceClaim(mine: true);
    }
  }

  /// The active profile is not this phone's owner: show ITS OWN server total,
  /// never this phone's steps.
  Future<StepTrackingState> _readOnlyState(StepRepository repo, String profileId,
      DeviceClaim claim, StepTrackingState previous) async {
    StepDay? today;
    String? error;
    try {
      final key = dateKey(DateTime.now());
      final rows = await repo.fetchDays(profileId, key, key);
      if (rows.isNotEmpty) {
        final r = rows.first;
        today = StepDay(
            localDate: r.localDate,
            offsetMin: offsetMinutesFor(DateTime.now()),
            source: StepSourceKind.healthStore,
            steps: r.steps,
            distanceM: r.distanceM,
            kcal: r.kcal,
            floors: r.floors);
      }
    } catch (e) {
      error = e.toString();
      today = previous.profileId == profileId ? previous.today : null;
    }
    return StepTrackingState(
      today: today,
      lastSync: error == null ? DateTime.now() : previous.lastSync,
      error: error,
      profileId: profileId,
      otherOwnerName: claim.ownerName,
      otherOwnerProfileId: claim.ownerProfileId,
      canMoveDevice: claim.canMove,
      foreignDevice: claim.ownerProfileId == null,
    );
  }

  /// Makes this phone count steps for the active profile (if the server's
  /// rules allow it). Throws [CustomError] with a clear message otherwise.
  Future<void> useThisPhoneForActiveProfile() async {
    final profile = await ref.read(activeProfileProvider.future);
    if (profile == null) return;
    final prefs = await SharedPreferences.getInstance();
    await ref
        .read(stepRepositoryProvider)
        .moveDevice(await loadDeviceId(prefs), profile.id);
    await refresh();
  }

  /// The background task has no Riverpod/UI, so it reads these.
  Future<void> _rememberForBackground(
      SharedPreferences prefs, String profileId, double? h, double? w) async {
    final uid = supabaseClient.auth.currentUser?.id;
    if (uid == null) return;
    await prefs.setString('bg_profile_$uid', profileId);
    await prefs.setString('bg_body_$profileId', jsonEncode({'h': h, 'w': w}));
  }

  Future<void> requestPermissions() async {
    final profile = await ref.read(activeProfileProvider.future);
    if (profile == null) return;
    for (final s in ref.read(stepSourcesProvider(profile.id))) {
      if (await s.availability() == SourceAvailability.needsPermission) {
        await s.requestPermission();
      }
    }
    final cur = state.value;
    if (cur != null) state = AsyncData(cur.copyWith(syncing: false));
    await refresh();
  }

  Future<void> installHealthConnect() async {
    final profile = await ref.read(activeProfileProvider.future);
    if (profile == null) return;
    for (final s in ref.read(stepSourcesProvider(profile.id))) {
      if (s is HealthStepSource) await s.installHealthConnect();
    }
  }
}

final stepTrackingProvider =
    AsyncNotifierProvider.autoDispose<StepTrackingController, StepTrackingState>(
        StepTrackingController.new);

/// Server history (this year and last) for the active profile.
final activityHistoryProvider =
    FutureProvider.autoDispose<ActivityHistory?>((ref) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return null;
  final repo = ref.watch(stepRepositoryProvider);
  final now = DateTime.now();
  final from = dateKey(DateTime(now.year - 1, 1, 1));
  final to = dateKey(DateTime(now.year, now.month, now.day + 8));
  final days = await repo.fetchDays(profile.id, from, to);
  final rest = await repo.fetchRestDays(profile.id, from, to);
  return ActivityHistory(
    days: {
      for (final d in days)
        d.localDate: DayRecord(
            steps: d.steps, distanceM: d.distanceM, kcal: d.kcal, floors: d.floors),
    },
    restDays: rest,
    goal: profile.dailyGoal,
  );
});
