import '../constants/firebase_constants.dart';
import '../models/custom_error.dart';
import '../models/walker_profile.dart';
import 'handle_exception.dart';

/// Household profiles (up to 6 per login). Privacy is enforced by RLS: a
/// login can only ever see and change its own profiles.
class ProfileRepository {
  String get _accountId => supabaseClient.auth.currentUser!.id;

  Future<List<WalkerProfile>> listProfiles() async {
    try {
      final rows = await supabaseClient
          .from('profiles')
          .select()
          .eq('account_id', _accountId)
          .order('created_at');
      return rows.map(WalkerProfile.fromMap).toList();
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<WalkerProfile> addProfile({
    required ProfileRelation relation,
    required WalkerProfile details,
  }) async {
    assert(relation != ProfileRelation.self, 'self is created at signup');
    try {
      final row = await supabaseClient
          .from('profiles')
          .insert({
            ...details.toWritableMap(),
            'account_id': _accountId,
            'relation': relation.name,
          })
          .select()
          .single();
      return WalkerProfile.fromMap(row);
    } catch (e) {
      throw _mapProfileError(e);
    }
  }

  Future<void> updateProfile(WalkerProfile profile) async {
    try {
      await supabaseClient
          .from('profiles')
          .update(profile.toWritableMap())
          .eq('id', profile.id);
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<void> deleteProfile(String profileId) async {
    try {
      await supabaseClient.from('profiles').delete().eq('id', profileId);
    } catch (e) {
      throw handleException(e);
    }
  }

  CustomError _mapProfileError(Object e) {
    if (e.toString().contains('profile limit reached')) {
      return const CustomError(
        code: 'profile-limit',
        message: 'You can have at most 6 profiles on one account.',
        plugin: 'supabase_db',
      );
    }
    return handleException(e);
  }
}
