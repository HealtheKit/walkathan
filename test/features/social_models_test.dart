import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/social/social_models.dart';

void main() {
  test('FriendsOverview parses; non-sharing friends have no steps', () {
    final o = FriendsOverview.fromMap({
      'code': 'AB12CD34', 'sharing': true,
      'friends': [
        {'profile_id': 'p1', 'name': 'Bhanu', 'hidden': false, 'sharing': true, 'today_steps': 9000},
        {'profile_id': 'p2', 'name': 'Chitra', 'hidden': true, 'sharing': false, 'today_steps': null},
      ],
      'incoming': [{'profile_id': 'p3', 'name': 'Dev'}],
      'outgoing': [], 'blocked': [{'profile_id': 'p4', 'name': 'Esha'}],
    });
    expect(o.code, 'AB12CD34');
    expect(o.friends[0].todaySteps, 9000);
    expect(o.friends[1].todaySteps, isNull);
    expect(o.friends[1].hidden, isTrue);
    expect(o.incoming.single.name, 'Dev');
    expect(o.blocked.single.name, 'Esha');
  });

  test('RankRow keeps hidden (null) steps as null', () {
    final rows = parseRankRows([
      {'rank': 1, 'profile_id': 'a', 'name': 'A', 'mine': false, 'steps': null},
      {'rank': 2, 'profile_id': 'b', 'name': 'B', 'mine': true, 'steps': 4000},
    ]);
    expect(rows[0].steps, isNull);
    expect(rows[1].steps, 4000);
    expect(parseRankRows(null), isEmpty);
  });

  test('GroupBoard parses group info, flags and my rows outside the top', () {
    final b = GroupBoard.fromMap({
      'group': {
        'id': 'g1', 'name': 'Team Alpha', 'my_role': 'admin', 'member_count': 3,
        'mystery_mode': true, 'chat_enabled': false, 'taunts_enabled': true,
        'challenge_start': '2026-11-01', 'challenge_end': '2026-11-30',
      },
      'steps_hidden': true, 'excludes_today': false,
      'rows': [{'rank': 1, 'profile_id': 'a', 'name': 'A', 'mine': false, 'steps': null}],
      'mine': [{'rank': 7, 'profile_id': 'me', 'name': 'Me', 'mine': true, 'steps': 10}],
    });
    expect(b.group.role, GroupRole.admin);
    expect(b.group.role.isAdmin, isTrue);
    expect(b.group.hasChallenge, isTrue);
    expect(b.group.chatEnabled, isFalse);
    expect(b.stepsHidden, isTrue);
    expect(b.mineOutsideTop.single.rank, 7);
  });

  test('GroupInfo from my_groups uses the role key; no challenge when dates are null', () {
    final g = GroupInfo.fromMap({'id': 'g', 'name': 'X', 'role': 'owner', 'member_count': 1,
      'challenge_start': null, 'challenge_end': null});
    expect(g.role, GroupRole.owner);
    expect(g.hasChallenge, isFalse);
    expect(GroupRole.parse('nonsense'), GroupRole.member);
    expect(GroupRole.member.isAdmin, isFalse);
  });

  test('report CSV is ranked, quoted and safe against spreadsheet formulas', () {
    final csv = groupReportCsv({
      'group': 'Team "A"', 'from': '2026-11-01', 'to': '2026-11-07',
      'rows': [
        {'name': 'Mem', 'role': 'member', 'total_steps': 13000, 'active_days': 2, 'best_day': 9000},
        {'name': '=HYPERLINK("x")', 'role': 'admin', 'total_steps': 6000, 'active_days': 2, 'best_day': 5000},
      ],
    });
    final lines = csv.trim().split('\n');
    expect(lines[0], '"Group","Team ""A"""');
    expect(lines.any((l) => l == 'rank,name,role,total_steps,active_days,best_day'), isTrue);
    expect(lines[lines.length - 2], '1,"Mem","member",13000,2,9000');
    expect(lines.last, startsWith('2,"\'=HYPERLINK'));
  });
}
