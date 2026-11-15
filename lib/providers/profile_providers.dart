import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/firebase_constants.dart';
import '../features/transfer/transfer_models.dart';
import '../models/walker_profile.dart';
import '../repositories/account_repository.dart';
import '../repositories/admin_repository.dart';
import '../repositories/profile_repository_provider.dart';
import '../repositories/transfer_repository.dart';

final accountRepositoryProvider =
    Provider<AccountRepository>((ref) => AccountRepository());

final adminRepositoryProvider =
    Provider<AdminRepository>((ref) => AdminRepository());

/// Whether the signed-in login is a Super Admin (server-verified).
final isSuperAdminProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(adminRepositoryProvider).isSuperAdmin(),
);

/// All profiles (1 to 6) of the signed-in login.
final profilesProvider = FutureProvider.autoDispose<List<WalkerProfile>>(
  (ref) => ref.watch(profileRepositoryProvider).listProfiles(),
);

/// Which profile is walking on THIS device. Stored locally per login.
class ActiveProfileIdNotifier extends AsyncNotifier<String?> {
  String get _key =>
      'active_profile_${supabaseClient.auth.currentUser?.id ?? 'none'}';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  Future<void> select(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, profileId);
    state = AsyncData(profileId);
  }
}

final activeProfileIdProvider =
    AsyncNotifierProvider<ActiveProfileIdNotifier, String?>(
        ActiveProfileIdNotifier.new);

/// The active profile: the stored choice if it still exists, otherwise the
/// login's own ("self") profile.
final activeProfileProvider =
    FutureProvider.autoDispose<WalkerProfile?>((ref) async {
  final profiles = await ref.watch(profilesProvider.future);
  if (profiles.isEmpty) return null;
  final storedId = await ref.watch(activeProfileIdProvider.future);
  return profiles.firstWhere(
    (p) => p.id == storedId,
    orElse: () => profiles.firstWhere((p) => p.isSelf,
        orElse: () => profiles.first),
  );
});

/// The signed-in login's staff role: super | organizer | verifier | viewer,
/// or null for ordinary members. The server enforces every permission.
final staffRoleProvider = FutureProvider.autoDispose<String?>(
  (ref) => ref.watch(adminRepositoryProvider).staffRole(),
);

extension StaffRole on String? {
  bool get canManage => this == 'super' || this == 'organizer';
  bool get canVerify => this == 'super' || this == 'verifier';
  bool get isStaff => this != null;
}

// ---------------------------------------------------------------- transfers

final transferRepositoryProvider =
    Provider<TransferRepository>((ref) => TransferRepository());

/// The member's own transfer requests.
final myTransfersProvider = FutureProvider.autoDispose<List<ProfileTransfer>>(
  (ref) => ref.watch(transferRepositoryProvider).mine(),
);

/// True for a Super Admin or an organizer of at least one event.
final isTransferReviewerProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(transferRepositoryProvider).isReviewer(),
);

final pendingTransferCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(transferRepositoryProvider).pendingCount(),
);
