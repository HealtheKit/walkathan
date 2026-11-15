import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:walkathan/features/activity/step_providers.dart';
import 'package:walkathan/features/social/social_models.dart';
import 'package:walkathan/features/social/social_providers.dart';
import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/content/social/group_detail_page.dart';
import 'package:walkathan/pages/content/social/group_settings_page.dart';
import 'package:walkathan/pages/content/social/social_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/theme/app_theme.dart';

class FakeTracking extends StepTrackingController {
  @override
  Future<StepTrackingState> build() async => const StepTrackingState();
  @override
  Future<void> refresh() async {}
}

class FakeSocial extends SocialRepository {
  FriendsOverview overview = const FriendsOverview(
      code: 'AB12CD34', sharing: true, friends: [], incoming: [], outgoing: [], blocked: []);
  List<RankRow> friendRows = const [];
  List<GroupInfo> groups = const [];
  GroupBoard? board;
  List<GroupMember> members = const [];
  String requestResult = 'sent';
  String joinResult = 'invalid';
  final calls = <String>[];

  @override
  Future<FriendsOverview> friendsOverview(String me) async => overview;
  @override
  Future<List<RankRow>> friendBoard(String me, SocialPeriod period) async => friendRows;
  @override
  Future<String> requestByCode(String me, String code) async {
    calls.add('request:$code');
    return requestResult;
  }
  @override
  Future<void> respond(String me, String other, bool accept) async => calls.add('respond:$other:$accept');
  @override
  Future<void> setHidden(String me, String other, bool hidden) async => calls.add('hide:$other:$hidden');
  @override
  Future<void> setBlocked(String me, String other, bool blocked) async => calls.add('block:$other:$blocked');
  @override
  Future<void> removeFriend(String me, String other) async => calls.add('remove:$other');
  @override
  Future<List<GroupInfo>> myGroups(String me) async => groups;
  @override
  Future<({String status, String? groupId})> joinGroup(String me, String code) async {
    calls.add('join:$code');
    return (status: joinResult, groupId: null);
  }
  @override
  Future<GroupBoard> groupBoard(String me, String groupId, SocialPeriod period) async {
    calls.add('board:${period.wire}');
    return board!;
  }
  @override
  Future<List<GroupMember>> groupMembers(String me, String groupId) async => members;
  @override
  Future<void> updateGroup(String me, String groupId,
      {String? name, bool? chat, bool? taunts, bool? mystery}) async =>
      calls.add('update:mystery=$mystery');
  @override
  Future<String> createInvite(String me, String groupId) async => 'AAAA-BBBB-CCCC';
}

const profile = WalkerProfile(
    id: 'me', accountId: 'a1', relation: ProfileRelation.self, displayName: 'Anu');

GroupInfo groupInfo(GroupRole role, {bool mystery = false, bool challenge = false}) => GroupInfo(
    id: 'g1', name: 'Team Alpha', role: role, memberCount: 3,
    mysteryMode: mystery, chatEnabled: true, tauntsEnabled: true,
    challengeStart: challenge ? DateTime(2026, 11, 1) : null,
    challengeEnd: challenge ? DateTime(2026, 11, 30) : null);

Future<FakeSocial> pump(WidgetTester tester, Widget page, FakeSocial fake,
    {Size size = const Size(420, 2600), double textScale = 1, Brightness b = Brightness.light}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      socialRepositoryProvider.overrideWithValue(fake),
      activeProfileProvider.overrideWith((ref) async => profile),
      profilesProvider.overrideWith((ref) async => [profile]),
      stepTrackingProvider.overrideWith(FakeTracking.new),
    ],
    child: MaterialApp(
      theme: b == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: true),
          child: child!),
      home: page,
    ),
  ));
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  group('Friends', () {
    testWidgets('no friends: explains consent and shows my code', (tester) async {
      await pump(tester, const SocialPage(), FakeSocial());
      expect(find.textContaining('only after you both agree'), findsOneWidget);
      expect(find.text('AB12CD34'), findsNothing); // inside a rich text span
      expect(find.textContaining('AB12CD34', findRichText: true), findsOneWidget);
    });

    testWidgets('sending a request reports each outcome plainly', (tester) async {
      final fake = await pump(tester, const SocialPage(), FakeSocial()..requestResult = 'not_found');
      await tester.enterText(find.byType(TextField), 'zz99');
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('request:zz99'));
      expect(find.textContaining('No one found with that code'), findsOneWidget);
    });

    testWidgets('board, requests, friend states and actions', (tester) async {
      final fake = FakeSocial()
        ..overview = const FriendsOverview(code: 'AB12CD34', sharing: false, friends: [
          Friend(profileId: 'p1', name: 'Bhanu', hidden: false, sharing: true, todaySteps: 9000),
          Friend(profileId: 'p2', name: 'Chitra', hidden: false, sharing: false),
          Friend(profileId: 'p5', name: 'Hari', hidden: true, sharing: true, todaySteps: 5),
        ], incoming: [PersonRef(profileId: 'p3', name: 'Dev')],
            outgoing: [PersonRef(profileId: 'p6', name: 'Gita')],
            blocked: [PersonRef(profileId: 'p4', name: 'Esha')])
        ..friendRows = const [
          RankRow(rank: 1, profileId: 'p1', name: 'Bhanu', mine: false, steps: 9000),
          RankRow(rank: 2, profileId: 'me', name: 'Anu', mine: true, steps: 7000),
        ];
      await pump(tester, const SocialPage(), fake);

      expect(find.bySemanticsLabel(RegExp(r'^Rank 1, Bhanu, 9,000 steps')), findsOneWidget);
      expect(find.textContaining('Your steps are hidden from friends'), findsOneWidget);
      expect(find.text('9000 steps today'), findsOneWidget);
      expect(find.text('Not sharing steps'), findsOneWidget);
      expect(find.text('Hidden from your lists'), findsOneWidget);
      expect(find.text('wants to be friends'), findsOneWidget);
      expect(find.text('Waiting for them'), findsOneWidget);
      expect(find.text('Blocked'), findsOneWidget);

      await tester.tap(find.byTooltip('Accept'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('respond:p3:true'));

      await tester.tap(find.byTooltip('Friend options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('block:p1:true'));

      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('block:p4:false'));
    });
  });

  group('Groups', () {
    testWidgets('empty: explains groups; a bad invite code is reported', (tester) async {
      final fake = await pump(tester, const SocialPage(), FakeSocial());
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expect(find.textContaining('private step challenges'), findsOneWidget);

      await tester.tap(find.text('Join with code'));
      await tester.pumpAndSettle();
      expect(find.textContaining('shares your name and step totals'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'aaaa-bbbb-cccc');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('join:aaaa-bbbb-cccc'));
      expect(find.textContaining('isn\'t valid'), findsOneWidget);
    });

    testWidgets('lists my groups with role and modes', (tester) async {
      await pump(tester, const SocialPage(),
          FakeSocial()..groups = [groupInfo(GroupRole.owner, mystery: true, challenge: true)]);
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      expect(find.text('Team Alpha'), findsOneWidget);
      expect(find.text('3 members · Owner · Mystery Mode · Challenge'), findsOneWidget);
    });

    testWidgets('Mystery Mode board: ranks shown, other counts hidden, mine visible',
        (tester) async {
      final fake = FakeSocial()
        ..board = GroupBoard(
            group: groupInfo(GroupRole.member, mystery: true),
            stepsHidden: true, excludesToday: false,
            rows: const [
              RankRow(rank: 1, profileId: 'p1', name: 'Adi', mine: false),
              RankRow(rank: 2, profileId: 'me', name: 'Anu', mine: true, steps: 4000),
            ],
            mine: const [RankRow(rank: 2, profileId: 'me', name: 'Anu', mine: true, steps: 4000)]);
      await pump(tester, const GroupDetailPage(groupId: 'g1'), fake);
      expect(find.textContaining('today shows ranks only'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Rank 1, Adi, steps hidden until tomorrow')), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Semantics && (w.properties.label ?? '').startsWith('Rank 2, Anu, you, 4,000 steps')),
          findsOneWidget);
      // a member gets "leave", not settings
      expect(find.byTooltip('Group settings'), findsNothing);
      // no challenge tab without a challenge
      expect(find.text('Challenge'), findsNothing);
    });

    testWidgets('admin sees settings and the Challenge tab; tab requests it',
        (tester) async {
      final fake = FakeSocial()
        ..board = GroupBoard(
            group: groupInfo(GroupRole.admin, challenge: true),
            stepsHidden: false, excludesToday: false,
            rows: const [RankRow(rank: 1, profileId: 'me', name: 'Anu', mine: true, steps: 10)],
            mine: const []);
      await pump(tester, const GroupDetailPage(groupId: 'g1'), fake);
      expect(find.byTooltip('Group settings'), findsOneWidget);
      await tester.tap(find.text('Challenge'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('board:challenge'));
    });

    testWidgets('settings: admin toggles Mystery Mode, gets a one-time invite code; '
        'only the owner can delete', (tester) async {
      final fake = FakeSocial()
        ..members = const [
          GroupMember(profileId: 'o', name: 'Owner', role: GroupRole.owner, mine: false),
          GroupMember(profileId: 'me', name: 'Anu', role: GroupRole.admin, mine: true),
          GroupMember(profileId: 'm', name: 'Mem', role: GroupRole.member, mine: false),
        ];
      await pump(tester, GroupSettingsPage(group: groupInfo(GroupRole.admin)), fake);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Mystery Mode'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('update:mystery=true'));

      await tester.tap(find.text('New invite code'));
      await tester.pumpAndSettle();
      expect(find.text('AAAA-BBBB-CCCC'), findsOneWidget);
      expect(find.textContaining('Shown only now'), findsOneWidget);

      expect(find.text('Delete group'), findsNothing, reason: 'admin is not the owner');
      expect(find.text('Leave group'), findsOneWidget);
      // an admin can act on plain members only: exactly one member menu
      expect(find.byTooltip('Member options'), findsOneWidget);
    });

    testWidgets('settings: owner can delete and manage every other member', (tester) async {
      final fake = FakeSocial()
        ..members = const [
          GroupMember(profileId: 'me', name: 'Anu', role: GroupRole.owner, mine: true),
          GroupMember(profileId: 'a', name: 'Adi', role: GroupRole.admin, mine: false),
          GroupMember(profileId: 'm', name: 'Mem', role: GroupRole.member, mine: false),
        ];
      await pump(tester, GroupSettingsPage(group: groupInfo(GroupRole.owner)), fake);
      expect(find.text('Delete group'), findsOneWidget);
      expect(find.byTooltip('Member options'), findsNWidgets(2));
    });
  });

  for (final b in Brightness.values) {
    for (final cfg in [
      (size: const Size(360, 3200), scale: 1.0, name: 'phone'),
      (size: const Size(360, 5600), scale: 2.0, name: 'phone, text x2'),
      (size: const Size(1024, 2400), scale: 1.0, name: 'tablet'),
    ]) {
      testWidgets('no overflow: social screens, ${cfg.name} / ${b.name}', (tester) async {
        FakeSocial full() => FakeSocial()
          ..overview = const FriendsOverview(code: 'AB12CD34', sharing: true, friends: [
            Friend(profileId: 'p1', name: 'A very long friend name that must truncate cleanly', hidden: false, sharing: true, todaySteps: 123456),
          ], incoming: [PersonRef(profileId: 'p3', name: 'Another quite long requester name')],
              outgoing: [], blocked: [])
          ..friendRows = const [RankRow(rank: 1, profileId: 'me', name: 'Anu', mine: true, steps: 1234567)]
          ..groups = [groupInfo(GroupRole.owner, mystery: true, challenge: true)]
          ..members = const [GroupMember(profileId: 'm', name: 'A long member name here', role: GroupRole.member, mine: false)]
          ..board = GroupBoard(group: groupInfo(GroupRole.owner, mystery: true, challenge: true),
              stepsHidden: true, excludesToday: false,
              rows: const [RankRow(rank: 1, profileId: 'p1', name: 'A very long walker name that truncates', mine: false)],
              mine: const []);
        await pump(tester, const SocialPage(), full(), size: cfg.size, textScale: cfg.scale, b: b);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Groups'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await pump(tester, const GroupDetailPage(groupId: 'g1'), full(), size: cfg.size, textScale: cfg.scale, b: b);
        expect(tester.takeException(), isNull);
        await pump(tester, GroupSettingsPage(group: groupInfo(GroupRole.owner)), full(), size: cfg.size, textScale: cfg.scale, b: b);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
