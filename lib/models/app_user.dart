class AppUser {
  final String id;
  final String name;
  final String email;

  const AppUser({
    this.id = '',
    this.name = '',
    this.email = '',
  });

  factory AppUser.fromMap(Map<String, dynamic> map) {
    return AppUser(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'email': email,
      };
}
