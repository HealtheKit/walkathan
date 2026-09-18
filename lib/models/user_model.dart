import 'package:supabase_flutter/supabase_flutter.dart';

enum UserRole { admin, moderator, member }
enum Gender { male, female }

class UserModel {
  final String uid;
  final String email;
  final UserRole role;
  final String? name;
  final Gender gender;

  UserModel({required this.uid, required this.email, required this.role, this.name, required this.gender});

  factory UserModel.fromSupabaseUser(User supabaseUser, {UserRole role = UserRole.member, String? name, Gender gender = Gender.male}) {
    return UserModel(uid: supabaseUser.id, email: supabaseUser.email ?? '', role: role, name: name, gender: gender);
  }

  Map<String, dynamic> toJson() => {
        'id': uid,
        'email': email,
        'role': role.name,
        'name': name,
        'gender': gender.name,
      };

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      uid: json['id'] ?? json['uid'] ?? '',
      email: json['email'] ?? '',
      role: UserRole.values.byName(json['role'] ?? 'member'),
      name: json['name'],
      gender: Gender.values.byName(json['gender'] ?? 'male'),
    );
  }
}