// Renders the screenshots used in docs/client-guide/index.html.
//
// Run from the project root:
//   flutter test tool/doc_screenshots/screenshots_test.dart --update-goldens
//
// Every screen is the real widget, filled with SAMPLE data (no network).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'package:walkathan/config/supabase_config.dart';
import 'package:walkathan/features/activity/history_math.dart';
import 'package:walkathan/features/activity/step_day.dart';
import 'package:walkathan/features/activity/step_providers.dart';
import 'package:walkathan/features/activity/step_source.dart';
import 'package:walkathan/features/admin/member_csv.dart';
import 'package:walkathan/features/events/event_models.dart';
import 'package:walkathan/features/events/event_providers.dart';
import 'package:walkathan/features/events/event_scoring.dart';
import 'package:walkathan/features/social/social_models.dart';
import 'package:walkathan/features/social/social_providers.dart';
import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/admin/admin_event_dashboard_page.dart';
import 'package:walkathan/pages/admin/admin_events_page.dart';
import 'package:walkathan/pages/admin/admin_members_page.dart';
import 'package:walkathan/pages/auth/signin/signin_page.dart';
import 'package:walkathan/pages/auth/welcome/welcome_page.dart';
import 'package:walkathan/pages/content/activity/activity_page.dart';
import 'package:walkathan/pages/content/event/event_dashboard_page.dart';
import 'package:walkathan/pages/content/event/my_event_progress_page.dart';
import 'package:walkathan/pages/content/home/home_page.dart';
import 'package:walkathan/pages/content/profiles/profile_edit_page.dart';
import 'package:walkathan/pages/content/profiles/profiles_page.dart';
import 'package:walkathan/pages/content/settings/settings_page.dart';
import 'package:walkathan/pages/content/social/group_detail_page.dart';
import 'package:walkathan/pages/content/social/group_settings_page.dart';
import 'package:walkathan/pages/content/social/social_page.dart';
import 'package:walkathan/pages/content/walk_home/walk_home_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/repositories/account_repository.dart';
import 'package:walkathan/repositories/admin_repository.dart';
import 'package:walkathan/theme/app_colors.dart';
import 'package:walkathan/theme/app_theme.dart';
import 'package:walkathan/theme/palette_provider.dart';

const _out = '../../docs/client-guide/images';
final now = DateTime(2026, 11, 14, 9, 5);

// ------------------------------------------------------------------ data
const me = WalkerProfile(
    id: 'p-me', accountId: 'a-me', relation: ProfileRelation.self, displayName: 'Priya',
    dailyGoal: 8000, sex: 'female', countryCode: 'KW', heightCm: 162, weightKg: 58);
const spouse = WalkerProfile(
    id: 'p-sp', accountId: 'a-me', relation: ProfileRelation.spouse, displayName: 'Karthik',
    dailyGoal: 10000, sex: 'male');
const child = WalkerProfile(
    id: 'p-ch', accountId: 'a-me', relation: ProfileRelation.child, displayName: 'Anu',
    dailyGoal: 6000, sex: 'female');

final event = MemberEvent(
    id: 'e1', name: 'TEF Winter Walkathon 2026',
    startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 30));

List<int> hrs(int h, int n) => [
      for (var i = 0; i < 24; i++)
        i == h ? (n * .6).round() : (i == h + 1 ? (n * .4).round() : 0)
    ];

class FakeTracking extends StepTrackingController {
  FakeTracking(this.s);
  final StepTrackingState s;
  @override
  Future<StepTrackingState> build() async => s;
  @override
  Future<void> refresh() async {}
}

StepTrackingState tracking(int steps, {int live = 0}) => StepTrackingState(
      today: StepDay(
          localDate: '2026-11-14', offsetMin: 180, source: StepSourceKind.healthStore,
          steps: steps, distanceM: (steps * .72).round(), kcal: steps ~/ 25),
      sources: const {StepSourceKind.healthStore: SourceAvailability.available},
      liveExtra: live,
      live: live > 0,
      lastSync: DateTime(2026, 11, 14, 9, 4),
      profileId: 'p-me',
    );

const _daily = [9200, 8400, 10100, 7600, 8800, 0, 9400, 11200, 8100, 8600, 3900, 9900, 10400];

ActivityHistory history() => ActivityHistory(
      days: {
        for (var d = 1; d <= 13; d++)
          '2026-11-${d.toString().padLeft(2, '0')}':
              DayRecord(steps: _daily[d - 1], distanceM: 6000, kcal: 330),
        '2026-10-24': const DayRecord(steps: 15800),
      },
      restDays: const {'2026-11-06'},
      goal: 8000,
    );

BoardRow row(int r, String id, String n, int s, {bool mine = false, int gap = 0}) => BoardRow(
    rank: r, profileId: id, name: n, steps: s, mine: mine, value: s, gap: gap,
    topPct: (100 * r / 48).ceil(), avg: s ~/ 13, activeDays: 12);

EventBoard board() => EventBoard(
      walkers: 48,
      activeWalkers: 44,
      totalSteps: 4386200,
      averageValue: 91400,
      rows: [
        row(1, 'p1', 'Lakshmi', 152300),
        row(2, 'p2', 'Arun', 140800),
        row(3, 'p3', 'Meena', 131200),
        row(4, 'p4', 'Siva', 120500),
        row(5, 'p-me', 'Priya', 115600, mine: true, gap: 4900),
        row(6, 'p6', 'Ravi', 109300),
        row(7, 'p7', 'Deepa', 101000),
      ],
      mine: [
        row(5, 'p-me', 'Priya', 115600, mine: true, gap: 4900),
        row(12, 'p-sp', 'Karthik', 86200, mine: true, gap: 1200),
        row(31, 'p-ch', 'Anu', 52400, mine: true, gap: 800),
      ],
    );

MyEventStats stats() => MyEventStats(
      config: EventConfig(
          startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 30),
          dailyTarget: 8000, rewardMinSteps: 150000, rewardMinActivePct: 70),
      days: [
        for (var d = 2; d <= 13; d++)
          if (d != 6)
            EventDayRecord(
                date: DateTime(2026, 11, d),
                steps: _daily[d - 1],
                distanceM: 6200,
                kcal: 330,
                hours: hrs(d == 11 ? 18 : 6, _daily[d - 1])),
      ],
      announcements: [
        (
          title: 'Week 2 begins',
          body: 'Great start, everyone! The women\'s board is very close this week.',
          at: DateTime(2026, 11, 9)
        ),
      ],
    );

GroupInfo groupInfo(GroupRole role) => GroupInfo(
    id: 'g1', name: 'Engineering Team', role: role, memberCount: 18,
    mysteryMode: true, chatEnabled: true, tauntsEnabled: true,
    challengeStart: DateTime(2026, 11, 10), challengeEnd: DateTime(2026, 11, 23));

class FakeSocial extends SocialRepository {
  @override
  Future<FriendsOverview> friendsOverview(String me) async => const FriendsOverview(
        code: 'K7Q2M9TX',
        sharing: true,
        friends: [
          Friend(profileId: 'f1', name: 'Meena', hidden: false, sharing: true, todaySteps: 4200),
          Friend(profileId: 'f2', name: 'Arun', hidden: false, sharing: true, todaySteps: 3100),
          Friend(profileId: 'f3', name: 'Deepa', hidden: false, sharing: false),
        ],
        incoming: [PersonRef(profileId: 'f4', name: 'Siva')],
        outgoing: [],
        blocked: [],
      );
  @override
  Future<List<RankRow>> friendBoard(String me, SocialPeriod period) async => const [
        RankRow(rank: 1, profileId: 'f1', name: 'Meena', mine: false, steps: 4200),
        RankRow(rank: 2, profileId: 'p-me', name: 'Priya', mine: true, steps: 3400),
        RankRow(rank: 3, profileId: 'f2', name: 'Arun', mine: false, steps: 3100),
      ];
  @override
  Future<List<GroupInfo>> myGroups(String me) async => [
        groupInfo(GroupRole.owner),
        const GroupInfo(
            id: 'g2', name: 'Salmiya Morning Walkers', role: GroupRole.member,
            memberCount: 26, mysteryMode: true, chatEnabled: true, tauntsEnabled: false),
      ];
  @override
  Future<GroupBoard> groupBoard(String me, String groupId, SocialPeriod period) async =>
      GroupBoard(
        group: groupInfo(GroupRole.owner),
        stepsHidden: true,
        excludesToday: false,
        rows: const [
          RankRow(rank: 1, profileId: 'x1', name: 'Arun', mine: false),
          RankRow(rank: 2, profileId: 'p-me', name: 'Priya', mine: true, steps: 3400),
          RankRow(rank: 3, profileId: 'x2', name: 'Meena', mine: false),
          RankRow(rank: 4, profileId: 'x3', name: 'Ravi', mine: false),
        ],
        mine: const [],
      );
  @override
  Future<List<GroupMember>> groupMembers(String me, String groupId) async => const [
        GroupMember(profileId: 'p-me', name: 'Priya', role: GroupRole.owner, mine: true),
        GroupMember(profileId: 'x1', name: 'Arun', role: GroupRole.admin, mine: false),
        GroupMember(profileId: 'x2', name: 'Meena', role: GroupRole.member, mine: false),
      ];
}

final walkEvent = WalkEvent(
    id: 'e1', name: 'TEF Winter Walkathon 2026',
    startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 30), memberCount: 48,
    dailyTarget: 8000, dailyCap: 40000, rewardMinSteps: 150000, rewardMinActivePct: 70);

class FakeAdmin extends AdminRepository {
  @override
  Future<bool> isSuperAdmin() async => true;
  @override
  Future<String?> staffRole() async => 'super';
  @override
  Future<List<WalkEvent>> listEvents() async => [
        walkEvent,
        WalkEvent(
            id: 'e2', name: 'Spring Family Walk 2027', startsOn: DateTime(2027, 3, 1),
            endsOn: DateTime(2027, 3, 21), memberCount: 0, status: 'draft'),
      ];
  @override
  Future<List<RosterEntry>> eventRoster(String eventId) async => const [
        RosterEntry(accountId: 'a1', email: 'arun.k@example.com', profileCount: 1, hasSignedIn: true),
        RosterEntry(accountId: 'a2', email: 'lakshmi.r@example.com', profileCount: 3, hasSignedIn: true),
        RosterEntry(accountId: 'a3', email: 'meena.s@example.com', profileCount: 2, hasSignedIn: true),
        RosterEntry(accountId: 'a4', email: 'ravi.p@example.com', profileCount: 0, hasSignedIn: false),
        RosterEntry(
            accountId: 'a5', email: 'siva.m@example.com', profileCount: 1, hasSignedIn: true,
            status: 'blocked'),
      ];
  @override
  Future<List<Member>> listMembers() async => [
        Member(accountId: 'a1', email: 'arun.k@example.com', createdAt: DateTime(2026, 10, 20),
            lastSignInAt: DateTime(2026, 11, 14), profileCount: 1, isDisabled: false),
        Member(accountId: 'a2', email: 'lakshmi.r@example.com', createdAt: DateTime(2026, 10, 20),
            lastSignInAt: DateTime(2026, 11, 13), profileCount: 3, isDisabled: false),
        Member(accountId: 'a4', email: 'ravi.p@example.com', createdAt: DateTime(2026, 10, 21),
            lastSignInAt: null, profileCount: 0, isDisabled: false),
        Member(accountId: 'a5', email: 'old.member@example.com', createdAt: DateTime(2026, 9, 2),
            lastSignInAt: DateTime(2026, 9, 30), profileCount: 1, isDisabled: true),
      ];
  @override
  Future<List<Map<String, dynamic>>> participantDays(String eventId, String profileId) async => [
        {'date': '2026-11-13', 'raw_steps': 10400, 'source': 'health_store'},
        {
          'date': '2026-11-12', 'raw_steps': 61200, 'source': 'phone_sensor',
          'correction': 'cap', 'cap_steps': 15000, 'reason': 'Phone left in a moving car'
        },
        {'date': '2026-11-11', 'raw_steps': 3900, 'source': 'health_store'},
        {'date': '2026-11-10', 'raw_steps': 8600, 'source': 'health_store'},
      ];
  @override
  Future<List<({String email, String role})>> listStaff() async => const [
        (email: 'organizer@example.com', role: 'organizer'),
        (email: 'checker@example.com', role: 'verifier'),
        (email: 'committee@example.com', role: 'viewer'),
      ];
  @override
  Future<List<ImportOutcome>> bulkImportChunk(String eventId, List<MemberRow> rows) async => [
        for (final r in rows)
          r.email.startsWith('arun')
              ? ImportOutcome(email: r.email, status: 'existing')
              : ImportOutcome(email: r.email, status: 'created', tempPassword: 'hT4kP9wQx2Lm'),
      ];
}

class FakeAccount extends AccountRepository {
  @override
  bool get mustChangePassword => true;
}

Map<String, dynamic> person(String id, String name, String email, String? sex, int total,
        int active, int pct, int cons, int imp, bool eligible, List<String> flags) =>
    {
      'profile_id': id, 'account_id': 'acc-$id', 'name': name, 'email': email, 'sex': sex,
      'status': 'active', 'total_steps': total, 'distance_m': (total * .72).round(),
      'active_days': active, 'event_days': 13, 'active_pct': pct, 'avg_daily': total ~/ 13,
      'consistency': cons, 'improvement': imp, 'reward_eligible': eligible, 'flags': flags,
      'last_active': '2026-11-12',
    };

final overview = <String, dynamic>{
  'event': {'status': 'published'},
  'participants': 48,
  'active_participants': 44,
  'active_today': 31,
  'total_steps': 4386200,
  'total_distance_m': 3158000,
  'synced_48h_pct': 92,
  'reward_eligible': 17,
  'last_board_update': '2026-11-14T06:02:00Z',
  'daily': [
    for (var d = 2; d <= 14; d++)
      {
        'date': '2026-11-${d.toString().padLeft(2, '0')}',
        'active': [38, 41, 40, 39, 30, 42, 44, 40, 39, 33, 41, 42, 31][d - 2],
        'steps': 300000
      },
  ],
  'participants_detail': [
    person('p1', 'Lakshmi', 'lakshmi.r@example.com', 'female', 152300, 13, 100, 88, 6200, true, []),
    person('p2', 'Arun', 'arun.k@example.com', 'male', 140800, 13, 100, 91, 2100, true, []),
    person('p8', 'Gopal', 'gopal.n@example.com', 'male', 98000, 6, 46, 31, -4000, false,
        ['high_values', 'low_consistency']),
    person('p9', 'Vani', 'vani.t@example.com', 'female', 21000, 4, 31, 22, -900, false, ['dropout_risk']),
    person('p10', 'Ravi', 'ravi.p@example.com', null, 0, 0, 0, 0, 0, false, ['no_data', 'sync_stale']),
  ],
};

// ------------------------------------------------------------- harness
Future<void> _fonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '/Volumes/cliss/development/flutter';
  Future<void> fam(String f, List<String> files) async {
    final l = FontLoader(f);
    for (final x in files) {
      final b = File('$root/bin/cache/artifacts/material_fonts/$x').readAsBytesSync();
      l.addFont(Future.value(ByteData.view(b.buffer)));
    }
    await l.load();
  }

  await fam('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await fam('MaterialIcons', ['MaterialIcons-Regular.otf']);
  // the import screen shows passwords in a monospace face; use Roboto here
  await fam('monospace', ['Roboto-Regular.ttf']);
}

class _FixedPalette extends PaletteNotifier {
  _FixedPalette(this.p);
  final AppPalette p;
  @override
  AppPalette build() => p;
}

List<Override> base({String? staff, AppPalette palette = AppPalette.tef, StepTrackingState? track}) => [
      activeProfileProvider.overrideWith((ref) async => me),
      profilesProvider.overrideWith((ref) async => [me, spouse, child]),
      staffRoleProvider.overrideWith((ref) async => staff),
      isSuperAdminProvider.overrideWith((ref) async => staff == 'super'),
      stepTrackingProvider.overrideWith(() => FakeTracking(track ?? tracking(5230, live: 42))),
      activityHistoryProvider.overrideWith((ref) async => history()),
      myEventsProvider.overrideWith((ref) async => [event]),
      eventBoardProvider.overrideWith((ref, key) async => board()),
      myEventStatsProvider.overrideWith((ref, id) async => stats()),
      socialRepositoryProvider.overrideWithValue(FakeSocial()),
      adminRepositoryProvider.overrideWithValue(FakeAdmin()),
      eventOverviewProvider.overrideWith((ref, id) async => overview),
      eventsProvider.overrideWith((ref) => FakeAdmin().listEvents()),
      membersProvider.overrideWith((ref) => FakeAdmin().listMembers()),
      paletteProvider.overrideWith(() => _FixedPalette(palette)),
    ];

Future<void> shoot(
  WidgetTester tester,
  String name,
  Widget page, {
  double height = 844,
  List<Override> extra = const [],
  Brightness b = Brightness.light,
  AppPalette palette = AppPalette.tef,
  String? staff,
  StepTrackingState? track,
  Future<void> Function()? act,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(780, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    retry: (c, e) => null,
    overrides: [...base(staff: staff, palette: palette, track: track), ...extra],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: b == Brightness.light ? AppTheme.light(palette) : AppTheme.dark(palette),
      builder: (c, child) =>
          MediaQuery(data: MediaQuery.of(c).copyWith(disableAnimations: true), child: child!),
      home: page,
    ),
  ));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
  if (act != null) {
    await act();
    await tester.pumpAndSettle();
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_out/$name.png'));
}

void main() {
  setUpAll(() async {
    await _fonts();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseAnonKey);
  });

  testWidgets('signin', (t) => shoot(t, 'signin', const SigninPage()));
  testWidgets('welcome', (t) => shoot(t, 'welcome', const WelcomePage(),
      height: 1000, extra: [accountRepositoryProvider.overrideWithValue(FakeAccount())]));
  testWidgets('home', (t) => shoot(t, 'home', HomePage(now: () => now)));
  testWidgets('walk', (t) => shoot(t, 'walk', const WalkHomePage(userId: 'a-me'), height: 900));
  testWidgets('walk_goal', (t) => shoot(t, 'walk_goal', const WalkHomePage(userId: 'a-me'),
      height: 900, track: tracking(9120)));
  testWidgets('activity', (t) => shoot(t, 'activity', ActivityPage(now: () => now), height: 2900));
  testWidgets('event', (t) => shoot(t, 'event', EventDashboardPage(now: () => now), height: 1500));
  testWidgets('progress', (t) =>
      shoot(t, 'progress', MyEventProgressPage(event: event, now: () => now), height: 3300));
  testWidgets('friends', (t) => shoot(t, 'friends', const SocialPage(), height: 1500));
  testWidgets('groups', (t) => shoot(t, 'groups', const SocialPage(),
      act: () async => t.tap(find.text('Groups'))));
  testWidgets('group_board', (t) => shoot(t, 'group_board', const GroupDetailPage(groupId: 'g1')));
  testWidgets('group_settings', (t) => shoot(t, 'group_settings',
      GroupSettingsPage(group: groupInfo(GroupRole.owner)), height: 2000));
  testWidgets('profiles', (t) => shoot(t, 'profiles', const ProfilesPage()));
  testWidgets('profile_edit', (t) =>
      shoot(t, 'profile_edit', const ProfileEditPage(profileId: 'p-me'), height: 1000));
  testWidgets('settings', (t) => shoot(t, 'settings', const SettingsPage(), height: 2200));
  testWidgets('theme_kuwait', (t) =>
      shoot(t, 'theme_kuwait', HomePage(now: () => now), palette: AppPalette.kuwait));
  testWidgets('theme_dark', (t) => shoot(t, 'theme_dark', EventDashboardPage(now: () => now),
      b: Brightness.dark, palette: AppPalette.kuwait));

  // ---- admin
  testWidgets('admin_events', (t) =>
      shoot(t, 'admin_events', const AdminEventsPage(), staff: 'super'));
  testWidgets('admin_event_detail', (t) =>
      shoot(t, 'admin_event_detail', EventDetailPage(event: walkEvent), staff: 'super'));
  testWidgets('admin_import', (t) => shoot(t, 'admin_import', BulkImportPage(event: walkEvent),
          height: 1100, staff: 'super', act: () async {
        await t.enterText(find.byType(TextField),
            'email,name\narun.k@example.com,Arun\nmeena.s@example.com,Meena\nfatima.a@example.com,Fatima\nnot-an-email\nmeena.s@example.com');
        await t.tap(find.text('Check list'));
      }));
  testWidgets('admin_import_done', (t) => shoot(t, 'admin_import_done',
          BulkImportPage(event: walkEvent), height: 1000, staff: 'super', act: () async {
        await t.enterText(find.byType(TextField),
            'arun.k@example.com\nmeena.s@example.com,Meena\nfatima.a@example.com,Fatima');
        await t.tap(find.text('Check list'));
        await t.pumpAndSettle();
        await t.tap(find.text('Import 3 members'));
      }));
  testWidgets('admin_members', (t) =>
      shoot(t, 'admin_members', const AdminMembersPage(), staff: 'super'));
  testWidgets('admin_dashboard', (t) => shoot(t, 'admin_dashboard',
      AdminEventDashboardPage(event: walkEvent), height: 2100, staff: 'super'));
  testWidgets('admin_participant', (t) => shoot(
      t,
      'admin_participant',
      AdminParticipantPage(
          event: walkEvent,
          participant: (overview['participants_detail'] as List)[2] as Map<String, dynamic>),
      height: 1100,
      staff: 'super'));
  testWidgets('admin_event_settings', (t) => shoot(t, 'admin_event_settings',
      AdminEventSettingsPage(event: walkEvent), height: 1400, staff: 'super'));
  testWidgets('admin_staff', (t) =>
      shoot(t, 'admin_staff', const AdminStaffPage(), staff: 'super'));
}
