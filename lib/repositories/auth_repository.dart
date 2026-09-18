import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/firebase_constants.dart';
import '../models/custom_error.dart';
import 'handle_exception.dart';

class AuthRepository {
  User? get currentUser => supabaseClient.auth.currentUser;

  Future<void> signup({
    required String name,
    required String email,
    required String password,
    required String gender,
  }) async {
    try {
      final response = await supabaseClient.auth.signUp(
        email: email,
        password: password,
        data: {
          'name': name,
          'gender': gender,
        },
      );

      final user = response.user;
      if (user == null) {
        throw const CustomError(
          code: 'signup-failed',
          message: 'Signup failed. Please try again.',
          plugin: 'supabase_auth',
        );
      }
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<void> signin({
    required String email,
    required String password,
  }) async {
    try {
      await supabaseClient.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<void> signout() async {
    try {
      await supabaseClient.auth.signOut();
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<void> changePassword(String password) async {
    try {
      await supabaseClient.auth.updateUser(
        UserAttributes(password: password),
      );
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      await supabaseClient.auth.resetPasswordForEmail(email);
    } catch (e) {
      throw handleException(e);
    }
  }

  // Supabase handles email verification via confirmation links automatically.
  // This is a no-op but kept for API compatibility.
  Future<void> sendEmailVerification() async {
    // Supabase sends confirmation email on signup automatically
    // if "Enable email confirmations" is turned on in the dashboard.
  }

  Future<void> reloadUser() async {
    // Supabase doesn't require explicit reload; session refreshes automatically.
    // We can force a session refresh if needed:
    try {
      await supabaseClient.auth.refreshSession();
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<void> reauthenticateWithCredential(
    String email,
    String password,
  ) async {
    try {
      await supabaseClient.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } catch (e) {
      throw handleException(e);
    }
  }
}
