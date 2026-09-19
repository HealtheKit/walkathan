import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/models/custom_error.dart';

void main() {
  group('CustomError', () {
    test('defaults all fields to empty strings', () {
      const error = CustomError();

      expect(error.code, '');
      expect(error.message, '');
      expect(error.plugin, '');
    });

    test('stores provided fields', () {
      const error = CustomError(
        code: 'auth-error',
        message: 'Incorrect email or password.',
        plugin: 'supabase_auth',
      );

      expect(error.code, 'auth-error');
      expect(error.message, 'Incorrect email or password.');
      expect(error.plugin, 'supabase_auth');
    });

    test('toString includes code, message, and plugin', () {
      const error = CustomError(
        code: 'db-error',
        message: 'A database error occurred.',
        plugin: 'supabase_db',
      );

      expect(
        error.toString(),
        'CustomError(code: db-error, message: A database error occurred., plugin: supabase_db)',
      );
    });

    test('implements Exception', () {
      const error = CustomError(code: 'x', message: 'y', plugin: 'z');
      expect(error, isA<Exception>());
    });
  });
}
