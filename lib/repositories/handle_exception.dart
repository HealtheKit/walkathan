import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/custom_error.dart';

String _friendlyAuthMessage(AuthException e) {
  final msg = e.message.toLowerCase();

  if (msg.contains('invalid login credentials') ||
      msg.contains('invalid_credentials')) {
    return 'Incorrect email or password. Please try again.';
  }
  if (msg.contains('email not confirmed')) {
    return 'Please verify your email before signing in. Check your inbox.';
  }
  if (msg.contains('user already registered') ||
      msg.contains('already been registered')) {
    return 'An account with this email already exists. Try signing in instead.';
  }
  if (msg.contains('password') && msg.contains('short')) {
    return 'Password is too short. Please use at least 6 characters.';
  }
  if (msg.contains('rate limit') || msg.contains('too many requests')) {
    return 'Too many attempts. Please wait a moment and try again.';
  }
  if (msg.contains('email') && msg.contains('invalid')) {
    return 'Please enter a valid email address.';
  }
  if (msg.contains('session') || msg.contains('token')) {
    return 'Your session has expired. Please sign in again.';
  }
  if (msg.contains('sending confirmation email') ||
      msg.contains('unexpected_failure')) {
    return 'Unable to send confirmation email. Please try again later or contact support.';
  }
  // Fallback: return the original message if no match
  return e.message;
}

String _friendlyDbMessage(PostgrestException e) {
  final msg = e.message.toLowerCase();
  final code = e.code ?? '';

  if (code == '42501' || msg.contains('row-level security')) {
    return 'Permission denied. Please sign out and sign back in.';
  }
  if (code == '23505' || msg.contains('duplicate') || msg.contains('unique')) {
    return 'This record already exists.';
  }
  if (msg.contains('not found') || code == 'PGRST116') {
    return 'The requested data could not be found.';
  }
  // Fallback
  return 'A database error occurred. Please try again later.';
}

CustomError handleException(dynamic e) {
  if (e is CustomError) return e;

  try {
    throw e;
  } on AuthException catch (e) {
    return CustomError(
      code: e.statusCode ?? 'auth-error',
      message: _friendlyAuthMessage(e),
      plugin: 'supabase_auth',
    );
  } on PostgrestException catch (e) {
    return CustomError(
      code: e.code ?? 'db-error',
      message: _friendlyDbMessage(e),
      plugin: 'supabase_db',
    );
  } catch (e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('sending confirmation email') ||
        msg.contains('unexpected_failure')) {
      return const CustomError(
        code: 'email-error',
        message: 'Unable to send confirmation email. Please try again later or contact support.',
        plugin: 'supabase_auth',
      );
    }
    if (msg.contains('rate limit') || msg.contains('too many requests')) {
      return const CustomError(
        code: 'rate-limit',
        message: 'Too many attempts. Please wait a moment and try again.',
        plugin: 'supabase_auth',
      );
    }
    return const CustomError(
      code: 'error',
      message: 'Something went wrong. Please try again.',
      plugin: 'supabase',
    );
  }
}
