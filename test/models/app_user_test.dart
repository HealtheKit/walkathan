import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/models/app_user.dart';

void main() {
  group('AppUser', () {
    test('defaults all fields to empty strings', () {
      const user = AppUser();

      expect(user.id, '');
      expect(user.name, '');
      expect(user.email, '');
    });

    test('constructor stores provided fields', () {
      const user = AppUser(id: 'u1', name: 'Alice', email: 'alice@example.com');

      expect(user.id, 'u1');
      expect(user.name, 'Alice');
      expect(user.email, 'alice@example.com');
    });

    group('fromMap', () {
      test('maps all present fields', () {
        final user = AppUser.fromMap({
          'id': 'u1',
          'name': 'Alice',
          'email': 'alice@example.com',
        });

        expect(user.id, 'u1');
        expect(user.name, 'Alice');
        expect(user.email, 'alice@example.com');
      });

      test('defaults missing fields to empty strings', () {
        final user = AppUser.fromMap(const <String, dynamic>{});

        expect(user.id, '');
        expect(user.name, '');
        expect(user.email, '');
      });

      test('defaults null fields to empty strings', () {
        final user = AppUser.fromMap({
          'id': null,
          'name': null,
          'email': null,
        });

        expect(user.id, '');
        expect(user.name, '');
        expect(user.email, '');
      });

      test('handles a partially populated map', () {
        final user = AppUser.fromMap({'id': 'u2'});

        expect(user.id, 'u2');
        expect(user.name, '');
        expect(user.email, '');
      });
    });

    group('toMap', () {
      test('serializes all fields', () {
        const user = AppUser(id: 'u1', name: 'Alice', email: 'alice@example.com');

        expect(user.toMap(), {
          'id': 'u1',
          'name': 'Alice',
          'email': 'alice@example.com',
        });
      });

      test('round-trips through fromMap', () {
        const original = AppUser(id: 'u3', name: 'Bob', email: 'bob@example.com');
        final roundTripped = AppUser.fromMap(original.toMap());

        expect(roundTripped.id, original.id);
        expect(roundTripped.name, original.name);
        expect(roundTripped.email, original.email);
      });
    });
  });
}
