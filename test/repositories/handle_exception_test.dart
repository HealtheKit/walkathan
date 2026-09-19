import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:walkathan/models/custom_error.dart';
import 'package:walkathan/repositories/handle_exception.dart';

void main() {
  group('handleException with CustomError', () {
    test('returns the same CustomError instance unchanged', () {
      const original = CustomError(code: 'x', message: 'y', plugin: 'z');
      expect(handleException(original), same(original));
    });
  });

  group('handleException with AuthException', () {
    test('invalid login credentials', () {
      final result = handleException(
        const AuthException('Invalid login credentials'),
      );

      expect(result.plugin, 'supabase_auth');
      expect(result.message, 'Incorrect email or password. Please try again.');
    });

    test('invalid_credentials code variant', () {
      final result = handleException(
        const AuthException('invalid_credentials error'),
      );
      expect(result.message, 'Incorrect email or password. Please try again.');
    });

    test('email not confirmed', () {
      final result = handleException(
        const AuthException('Email not confirmed'),
      );
      expect(result.message, 'Please verify your email before signing in. Check your inbox.');
    });

    test('user already registered', () {
      final result = handleException(
        const AuthException('User already registered'),
      );
      expect(result.message, 'An account with this email already exists. Try signing in instead.');
    });

    test('already been registered variant', () {
      final result = handleException(
        const AuthException('This email has already been registered'),
      );
      expect(result.message, 'An account with this email already exists. Try signing in instead.');
    });

    test('password too short', () {
      final result = handleException(
        const AuthException('Password is too short'),
      );
      expect(result.message, 'Password is too short. Please use at least 6 characters.');
    });

    test('rate limit', () {
      final result = handleException(
        const AuthException('Rate limit exceeded'),
      );
      expect(result.message, 'Too many attempts. Please wait a moment and try again.');
    });

    test('too many requests variant', () {
      final result = handleException(
        const AuthException('Too many requests'),
      );
      expect(result.message, 'Too many attempts. Please wait a moment and try again.');
    });

    test('invalid email', () {
      final result = handleException(
        const AuthException('Email address is invalid'),
      );
      expect(result.message, 'Please enter a valid email address.');
    });

    test('expired session', () {
      final result = handleException(
        const AuthException('Session expired'),
      );
      expect(result.message, 'Your session has expired. Please sign in again.');
    });

    test('invalid token', () {
      final result = handleException(
        const AuthException('Invalid token'),
      );
      expect(result.message, 'Your session has expired. Please sign in again.');
    });

    test('confirmation email failure', () {
      final result = handleException(
        const AuthException('Error sending confirmation email'),
      );
      expect(
        result.message,
        'Unable to send confirmation email. Please try again later or contact support.',
      );
    });

    test('unexpected_failure variant', () {
      final result = handleException(
        const AuthException('unexpected_failure occurred'),
      );
      expect(
        result.message,
        'Unable to send confirmation email. Please try again later or contact support.',
      );
    });

    test('unrecognized message falls back to the original message', () {
      final result = handleException(
        const AuthException('Some unmapped auth failure'),
      );
      expect(result.message, 'Some unmapped auth failure');
    });

    test('uses statusCode as the error code, defaulting to auth-error', () {
      final withStatus = handleException(
        const AuthException('boom', statusCode: '400'),
      );
      expect(withStatus.code, '400');

      final withoutStatus = handleException(
        const AuthException('boom'),
      );
      expect(withoutStatus.code, 'auth-error');
    });
  });

  group('handleException with PostgrestException', () {
    test('row-level security violation by code', () {
      final result = handleException(
        const PostgrestException(message: 'denied', code: '42501'),
      );
      expect(result.plugin, 'supabase_db');
      expect(result.message, 'Permission denied. Please sign out and sign back in.');
    });

    test('row-level security violation by message', () {
      final result = handleException(
        const PostgrestException(message: 'row-level security policy violated'),
      );
      expect(result.message, 'Permission denied. Please sign out and sign back in.');
    });

    test('duplicate key by code', () {
      final result = handleException(
        const PostgrestException(message: 'conflict', code: '23505'),
      );
      expect(result.message, 'This record already exists.');
    });

    test('duplicate key by message', () {
      final result = handleException(
        const PostgrestException(message: 'duplicate key value'),
      );
      expect(result.message, 'This record already exists.');
    });

    test('unique constraint by message', () {
      final result = handleException(
        const PostgrestException(message: 'unique constraint failed'),
      );
      expect(result.message, 'This record already exists.');
    });

    test('not found by message', () {
      final result = handleException(
        const PostgrestException(message: 'Row not found'),
      );
      expect(result.message, 'The requested data could not be found.');
    });

    test('not found by PGRST116 code', () {
      final result = handleException(
        const PostgrestException(message: 'no rows', code: 'PGRST116'),
      );
      expect(result.message, 'The requested data could not be found.');
    });

    test('unrecognized error falls back to generic database message', () {
      final result = handleException(
        const PostgrestException(message: 'weird error', code: '99999'),
      );
      expect(result.message, 'A database error occurred. Please try again later.');
    });

    test('uses the exception code, defaulting to db-error', () {
      final withCode = handleException(
        const PostgrestException(message: 'x', code: '500'),
      );
      expect(withCode.code, '500');

      final withoutCode = handleException(
        const PostgrestException(message: 'x'),
      );
      expect(withoutCode.code, 'db-error');
    });
  });

  group('handleException with generic exceptions', () {
    test('confirmation email failure text maps to email-error', () {
      final result = handleException(Exception('Error sending confirmation email'));

      expect(result.code, 'email-error');
      expect(result.plugin, 'supabase_auth');
      expect(
        result.message,
        'Unable to send confirmation email. Please try again later or contact support.',
      );
    });

    test('unexpected_failure text maps to email-error', () {
      final result = handleException(Exception('unexpected_failure'));
      expect(result.code, 'email-error');
    });

    test('rate limit text maps to rate-limit', () {
      final result = handleException(Exception('rate limit hit'));

      expect(result.code, 'rate-limit');
      expect(result.plugin, 'supabase_auth');
      expect(result.message, 'Too many attempts. Please wait a moment and try again.');
    });

    test('too many requests text maps to rate-limit', () {
      final result = handleException(Exception('too many requests'));
      expect(result.code, 'rate-limit');
    });

    test('unrecognized generic exception maps to a generic fallback', () {
      final result = handleException(Exception('anything else'));

      expect(result.code, 'error');
      expect(result.plugin, 'supabase');
      expect(result.message, 'Something went wrong. Please try again.');
    });

    test('non-Exception objects (e.g. a plain string) are also handled', () {
      final result = handleException('a raw string error');

      expect(result.code, 'error');
      expect(result.plugin, 'supabase');
    });
  });
}
