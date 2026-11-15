import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/models/walker_profile.dart';

void main() {
  group('ProfileRelation', () {
    test('parses known values and falls back to other', () {
      expect(ProfileRelation.parse('spouse'), ProfileRelation.spouse);
      expect(ProfileRelation.parse('child'), ProfileRelation.child);
      expect(ProfileRelation.parse('nonsense'), ProfileRelation.other);
      expect(ProfileRelation.parse(null), ProfileRelation.other);
    });
  });

  group('WalkerProfile', () {
    final row = {
      'id': 'p1',
      'account_id': 'a1',
      'relation': 'self',
      'display_name': 'Priya',
      'country_code': 'KW',
      'height_cm': 162,
      'weight_kg': 58.5,
      'birth_year': 1990,
      'sex': 'female',
      'daily_goal': 10000,
      'steps_visibility': 'friends',
    };

    test('fromMap maps every field', () {
      final p = WalkerProfile.fromMap(row);
      expect(p.id, 'p1');
      expect(p.accountId, 'a1');
      expect(p.isSelf, isTrue);
      expect(p.displayName, 'Priya');
      expect(p.countryCode, 'KW');
      expect(p.heightCm, 162.0);
      expect(p.weightKg, 58.5);
      expect(p.birthYear, 1990);
      expect(p.dailyGoal, 10000);
      expect(p.shareWithFriends, isTrue);
    });

    test('defaults: shares with accepted friends, 8000 steps, no body details', () {
      final p = WalkerProfile.fromMap({
        'id': 'p2',
        'account_id': 'a1',
        'relation': 'child',
      });
      expect(p.shareWithFriends, isTrue);
      expect(p.dailyGoal, WalkerProfile.defaultGoal);
      expect(p.heightCm, isNull);
      expect(p.displayName, '');
      expect(p.isSelf, isFalse);
    });

    test('toWritableMap only contains client-writable columns', () {
      final map = WalkerProfile.fromMap(row).toWritableMap();
      expect(map.keys, isNot(contains('id')));
      expect(map.keys, isNot(contains('account_id')));
      expect(map.keys, isNot(contains('relation')));
      expect(map['steps_visibility'], 'friends');
      expect(map['display_name'], 'Priya');
    });

    test('private profile writes steps_visibility private', () {
      final p = WalkerProfile.fromMap({...row, 'steps_visibility': 'private'});
      expect(p.toWritableMap()['steps_visibility'], 'private');
    });

    test('initial handles empty and non-latin names', () {
      expect(WalkerProfile.fromMap({...row, 'display_name': ''}).initial, '?');
      expect(WalkerProfile.fromMap({...row, 'display_name': '  anu'}).initial, 'A');
      expect(WalkerProfile.fromMap({...row, 'display_name': 'தமிழ்'}).initial, 'த');
    });
  });
}
