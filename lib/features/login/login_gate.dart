import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/firebase_constants.dart';
import '../../providers/profile_providers.dart';
import '../../repositories/auth_repository_provider.dart';
import '../activity/step_providers.dart' show loadDeviceId;
import '../transfer/transfer_models.dart';

/// Where a signed-in user is on the way into the app.
enum LoginStage {
  /// Asking the server whether this phone is known.
  checking,

  /// A NEW phone: waiting for a Super Admin / organizer to approve it.
  devicePending,

  /// An approver said no.
  deviceRejected,

  /// The server could not be reached and this phone was never approved here.
  deviceError,

  /// Phone is fine; the user picks who is walking on it.
  chooseProfile,

  /// In.
  ready,
}

class LoginGateState {
  const LoginGateState(this.stage, {this.note});
  final LoginStage stage;

  /// The approver's note on a rejection.
  final String? note;
}

/// Runs after every sign-in: first the phone check (a phone this login has
/// used before goes straight through; a new one needs approval), then the
/// profile selection screen. Reset on sign-out.
class LoginGate extends Notifier<LoginGateState> {
  Timer? _poll;

  @override
  LoginGateState build() {
    ref.onDispose(() => _poll?.cancel());
    // Rebuild only when a DIFFERENT user signs in or out, not on every
    // token refresh.
    final uid = ref.watch(
        authStateStreamProvider.select((s) => s.value?.session?.user.id)) ??
        supabaseClient.auth.currentUser?.id;
    if (uid == null) {
      // Signed out: the next sign-in must show the profile list again.
      Future<void>(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_pickedKey);
      });
      return const LoginGateState(LoginStage.ready);
    }
    Future<void>(() => _check(uid));
    return const LoginGateState(LoginStage.checking);
  }

  /// Which login already chose a profile since it signed in. Cleared on
  /// sign-out, so the list shows at EVERY login but not every time the app
  /// is merely reopened.
  static const _pickedKey = 'profile_picked_uid';

  String get _label => switch (defaultTargetPlatform) {
        TargetPlatform.iOS => 'iPhone',
        TargetPlatform.android => 'Android phone',
        _ => 'Phone',
      };

  Future<void> _check(String uid, {bool retry = false}) async {
    _poll?.cancel();
    final prefs = await SharedPreferences.getInstance();
    final okKey = 'device_ok_$uid';
    try {
      final deviceId = await loadDeviceId(prefs);
      final r = await ref
          .read(transferRepositoryProvider)
          .registerDevice(deviceId, _label, retry: retry);
      switch (r.status) {
        case DeviceStatus.approved:
          await prefs.setBool(okKey, true);
          await _afterApproved();
        case DeviceStatus.pending:
          await prefs.remove(okKey);
          state = const LoginGateState(LoginStage.devicePending);
          // Continue automatically once an approver decides.
          _poll = Timer.periodic(const Duration(seconds: 15), (_) => _check(uid));
        case DeviceStatus.rejected:
          await prefs.remove(okKey);
          state = LoginGateState(LoginStage.deviceRejected, note: r.note);
      }
    } catch (_) {
      // Offline: a phone approved before may continue; a never-approved one
      // cannot (the server would refuse its uploads anyway).
      if (prefs.getBool(okKey) == true) {
        await _afterApproved();
      } else {
        state = const LoginGateState(LoginStage.deviceError);
      }
    }
  }

  Future<void> _afterApproved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uid = supabaseClient.auth.currentUser?.id;
      if (uid != null && prefs.getString(_pickedKey) == uid) {
        state = const LoginGateState(LoginStage.ready); // chosen at this login
        return;
      }
      final profiles = await ref.read(profilesProvider.future);
      // Every login lists the profiles, even when there is only one.
      state = LoginGateState(
          profiles.isEmpty ? LoginStage.ready : LoginStage.chooseProfile);
    } catch (_) {
      state = const LoginGateState(LoginStage.ready); // profiles load later
    }
  }

  /// "Check again" on the waiting screen.
  Future<void> recheck() async {
    final uid = supabaseClient.auth.currentUser?.id;
    if (uid == null) return;
    state = const LoginGateState(LoginStage.checking);
    await _check(uid);
  }

  /// After a rejection: ask the approvers again.
  Future<void> askAgain() async {
    final uid = supabaseClient.auth.currentUser?.id;
    if (uid == null) return;
    state = const LoginGateState(LoginStage.checking);
    await _check(uid, retry: true);
  }

  /// The user tapped a profile on the selection screen.
  Future<void> choose(String profileId) async {
    await ref.read(activeProfileIdProvider.notifier).select(profileId);
    final uid = supabaseClient.auth.currentUser?.id;
    if (uid != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pickedKey, uid);
    }
    state = const LoginGateState(LoginStage.ready);
  }
}

final loginGateProvider =
    NotifierProvider<LoginGate, LoginGateState>(LoginGate.new);
