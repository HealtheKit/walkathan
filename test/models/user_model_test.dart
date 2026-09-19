import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:walkathan/models/user_model.dart';

User _buildSupabaseUser({String? email}) {
  return User(
    id: 'u1',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: DateTime(2024).toIso8601String(),
    email: email,
  );
}

void main() {
  group('UserModel.fromSupabaseUser', () {
    test('uses the supabase user id and email with default role/gender', () {
      final model = UserModel.fromSupabaseUser(_buildSupabaseUser(email: 'a@b.com'));

      expect(model.uid, 'u1');
      expect(model.email, 'a@b.com');
      expect(model.role, UserRole.member);
      expect(model.gender, Gender.male);
      expect(model.name, isNull);
    });

    test('defaults email to empty string when supabase user has none', () {
      final model = UserModel.fromSupabaseUser(_buildSupabaseUser());
      expect(model.email, '');
    });

    test('honors explicit role, name, and gender overrides', () {
      final model = UserModel.fromSupabaseUser(
        _buildSupabaseUser(email: 'a@b.com'),
        role: UserRole.admin,
        name: 'Alice',
        gender: Gender.female,
      );

      expect(model.role, UserRole.admin);
      expect(model.name, 'Alice');
      expect(model.gender, Gender.female);
    });
  });

  group('UserModel.toJson', () {
    test('serializes uid as id and enums by name', () {
      final model = UserModel(
        uid: 'u1',
        email: 'a@b.com',
        role: UserRole.moderator,
        name: 'Alice',
        gender: Gender.female,
      );

      expect(model.toJson(), {
        'id': 'u1',
        'email': 'a@b.com',
        'role': 'moderator',
        'name': 'Alice',
        'gender': 'female',
      });
    });

    test('serializes a null name as null', () {
      final model = UserModel(
        uid: 'u1',
        email: 'a@b.com',
        role: UserRole.member,
        gender: Gender.male,
      );

      expect(model.toJson()['name'], isNull);
    });
  });

  group('UserModel.fromJson', () {
    test('parses a fully populated json map', () {
      final model = UserModel.fromJson({
        'id': 'u1',
        'email': 'a@b.com',
        'role': 'admin',
        'name': 'Alice',
        'gender': 'female',
      });

      expect(model.uid, 'u1');
      expect(model.email, 'a@b.com');
      expect(model.role, UserRole.admin);
      expect(model.name, 'Alice');
      expect(model.gender, Gender.female);
    });

    test('falls back to "uid" key when "id" is absent', () {
      final model = UserModel.fromJson({'uid': 'u2', 'email': 'b@c.com'});
      expect(model.uid, 'u2');
    });

    test('defaults role to member and gender to male when absent', () {
      final model = UserModel.fromJson({'id': 'u1', 'email': 'a@b.com'});

      expect(model.role, UserRole.member);
      expect(model.gender, Gender.male);
    });

    test('defaults id and email to empty string when absent', () {
      final model = UserModel.fromJson(const <String, dynamic>{});

      expect(model.uid, '');
      expect(model.email, '');
    });

    test('throws when role or gender is not a recognized enum name', () {
      expect(
        () => UserModel.fromJson({'id': 'u1', 'email': 'a@b.com', 'role': 'superadmin'}),
        throwsArgumentError,
      );
      expect(
        () => UserModel.fromJson({'id': 'u1', 'email': 'a@b.com', 'gender': 'other'}),
        throwsArgumentError,
      );
    });

    test('round-trips through toJson', () {
      final original = UserModel(
        uid: 'u1',
        email: 'a@b.com',
        role: UserRole.admin,
        name: 'Alice',
        gender: Gender.female,
      );

      final roundTripped = UserModel.fromJson(original.toJson());

      expect(roundTripped.uid, original.uid);
      expect(roundTripped.email, original.email);
      expect(roundTripped.role, original.role);
      expect(roundTripped.name, original.name);
      expect(roundTripped.gender, original.gender);
    });
  });
}
