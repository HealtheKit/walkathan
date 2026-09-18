import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../repositories/profile_repository_provider.dart';
import '../../../models/app_user.dart';

final profileProvider = FutureProvider.family<AppUser, String>((ref, uid) {
  return ref.watch(profileRepositoryProvider).getProfile(uid: uid);
});
