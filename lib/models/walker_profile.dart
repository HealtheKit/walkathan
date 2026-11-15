/// Relationship of a walker profile to the household account.
enum ProfileRelation {
  self,
  spouse,
  child,
  other;

  static ProfileRelation parse(String? value) => ProfileRelation.values
      .firstWhere((r) => r.name == value, orElse: () => ProfileRelation.other);

  String get label => switch (this) {
        ProfileRelation.self => 'Me',
        ProfileRelation.spouse => 'Spouse',
        ProfileRelation.child => 'Child',
        ProfileRelation.other => 'Other',
      };
}

/// One walker. A login (account) owns 1 to 6 of these.
class WalkerProfile {
  const WalkerProfile({
    required this.id,
    required this.accountId,
    required this.relation,
    required this.displayName,
    this.countryCode,
    this.heightCm,
    this.weightKg,
    this.birthYear,
    this.sex,
    this.dailyGoal = defaultGoal,
    this.shareWithFriends = true,
    this.resyncRequestedAt,
  });

  static const int defaultGoal = 8000;

  final String id;
  final String accountId;
  final ProfileRelation relation;
  final String displayName;
  final String? countryCode;
  final double? heightCm;
  final double? weightKg;
  final int? birthYear;
  final String? sex;
  final int dailyGoal;

  /// `steps_visibility == 'friends'`: accepted friends can see steps.
  final bool shareWithFriends;

  /// Set by staff when this profile's history should be uploaded again.
  final DateTime? resyncRequestedAt;

  bool get isSelf => relation == ProfileRelation.self;

  String get initial {
    final t = displayName.trim();
    return t.isEmpty ? '?' : String.fromCharCode(t.runes.first).toUpperCase();
  }

  factory WalkerProfile.fromMap(Map<String, dynamic> map) {
    return WalkerProfile(
      id: map['id'] as String,
      accountId: map['account_id'] as String,
      relation: ProfileRelation.parse(map['relation'] as String?),
      displayName: (map['display_name'] as String?) ?? '',
      countryCode: map['country_code'] as String?,
      heightCm: (map['height_cm'] as num?)?.toDouble(),
      weightKg: (map['weight_kg'] as num?)?.toDouble(),
      birthYear: map['birth_year'] as int?,
      sex: map['sex'] as String?,
      dailyGoal: (map['daily_goal'] as int?) ?? defaultGoal,
      shareWithFriends: map['steps_visibility'] != 'private',
      resyncRequestedAt: DateTime.tryParse((map['resync_requested_at'] as String?) ?? ''),
    );
  }

  /// Columns a client is allowed to write (matches the column grants).
  Map<String, dynamic> toWritableMap() => {
        'display_name': displayName.trim(),
        'country_code': countryCode,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'birth_year': birthYear,
        'sex': sex,
        'daily_goal': dailyGoal,
        'steps_visibility': shareWithFriends ? 'friends' : 'private',
      };
}
