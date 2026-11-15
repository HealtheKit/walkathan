import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../constants/firebase_constants.dart';
import '../models/custom_error.dart';
import 'handle_exception.dart';

/// Account-level actions: first-login completion, feedback, deletion.
class AccountRepository {
  User? get _user => supabaseClient.auth.currentUser;

  /// True when the admin issued a temporary password that must be replaced.
  bool get mustChangePassword =>
      _user?.userMetadata?['must_change_password'] == true;

  bool get hasConsented => _user?.userMetadata?[AppConfig.consentKey] == true;

  /// Completes first login: optional new password + consent in one update.
  Future<void> completeFirstLogin({String? newPassword}) async {
    try {
      await supabaseClient.auth.updateUser(UserAttributes(
        password: newPassword,
        data: {
          'must_change_password': false,
          AppConfig.consentKey: true,
        },
      ));
    } catch (e) {
      throw handleException(e);
    }
  }

  /// Sends feedback with non-health diagnostics only.
  Future<void> sendFeedback(String message) async {
    try {
      await supabaseClient.from('feedback').insert({
        'account_id': _user!.id,
        'message': message.trim(),
        'diagnostics': {
          'platform': defaultTargetPlatform.name,
          'release_mode': kReleaseMode,
        },
      });
    } catch (e) {
      throw handleException(e);
    }
  }

  /// Deletes the whole account (all profiles and data) after re-checking
  /// the password server-side.
  Future<void> deleteAccount(String password) async {
    try {
      await supabaseClient.functions
          .invoke('delete-account', body: {'password': password});
      // The server already deleted the user; drop the local session too.
      try {
        await supabaseClient.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
    } on FunctionException catch (e) {
      final details = e.details;
      final msg = details is Map ? details['error']?.toString() : null;
      throw CustomError(
        code: 'delete-${e.status}',
        message: msg == 'incorrect password'
            ? 'Incorrect password.'
            : (msg ?? 'Could not delete the account. Please try again.'),
        plugin: 'edge_function',
      );
    } catch (e) {
      throw handleException(e);
    }
  }
}
