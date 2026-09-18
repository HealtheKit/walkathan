import '../constants/firebase_constants.dart';
import '../models/app_user.dart';
import '../models/custom_error.dart';
import 'handle_exception.dart';

class ProfileRepository {
  Future<AppUser> getProfile({required String uid}) async {
    try {
      final data = await supabaseClient
          .from('users')
          .select()
          .eq('id', uid)
          .maybeSingle();

      if (data != null) {
        return AppUser.fromMap(data);
      }

      // Fallback: create the user row from auth metadata if it doesn't exist
      final authUser = supabaseClient.auth.currentUser;
      if (authUser != null && authUser.id == uid) {
        final meta = authUser.userMetadata ?? {};
        final row = {
          'id': uid,
          'name': meta['name'] ?? '',
          'email': authUser.email ?? '',
          'gender': meta['gender'] ?? 'male',
        };

        await supabaseClient.from('users').upsert(row);
        return AppUser.fromMap(row);
      }

      throw const CustomError(
        code: 'user-not-found',
        message: 'Your profile could not be found. Please try signing out and signing back in.',
        plugin: 'supabase_db',
      );
    } on CustomError {
      rethrow;
    } catch (e) {
      throw handleException(e);
    }
  }
}
