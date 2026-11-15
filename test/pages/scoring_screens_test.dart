import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:walkathan/features/activity/step_providers.dart';
import 'package:walkathan/features/events/event_models.dart';
import 'package:walkathan/features/events/event_providers.dart';
import 'package:walkathan/features/events/event_scoring.dart';
import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/admin/admin_event_dashboard_page.dart';
import 'package:walkathan/pages/content/event/my_event_progress_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/repositories/admin_repository.dart';
import 'package:walkathan/theme/app_theme.dart';

class FakeTracking extends StepTrackingController {
  @override
  Future<StepTrackingState> build() async => const StepTrackingState();
  @override
  Future<void> refresh() async {}
}

final now = DateTime(2026, 11, 13, 10);
final event = MemberEvent(id: 'e1', name: 'Spring Walkathon',
    startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 15));
const profile = WalkerProfile(id: 'me', accountId: 'a', relation: ProfileRelation.self, displayName: 'Anu', sex: 'female');

List<int> hrs(int h, int n) => [for (var i = 0; i < 24; i++) i == h ? n : 0];

MyEventStats stats() => MyEventStats(
      config: EventConfig(startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 15),
          dailyTarget: 5000, rewardMinSteps: 30000, rewardMinActivePct: 50),
      days: [
        for (var d = 2; d <= 8; d++)
          EventDayRecord(date: DateTime(2026, 11, d), steps: 6000, distanceM: 4500, kcal: 240, hours: hrs(7, 6000)),
        EventDayRecord(date: DateTime(2026, 11, 11), steps: 2000, hours: hrs(18, 2000)),
        EventDayRecord(date: DateTime(2026, 11, 12), steps: 1000),
      ],
      announcements: [(title: 'Welcome', body: 'Day one', at: DateTime(2026, 11, 2))],
    );

final overview = <String, dynamic>{
  'event': {'status': 'published'},
  'participants': 3, 'active_participants': 2, 'active_today': 1,
  'total_steps': 123456, 'total_distance_m': 90000, 'synced_48h_pct': 67,
  'reward_eligible': 1, 'last_board_update': '2026-11-13T09:00:00Z',
  'daily': [
    {'date': '2026-11-02', 'active': 2, 'steps': 12000},
    {'date': '2026-11-03', 'active': 1, 'steps': 6000},
  ],
  'participants_detail': [
    {'profile_id': 'p1', 'account_id': 'a1', 'name': 'Mani', 'email': 'm@example.com', 'sex': 'male',
     'status': 'active', 'total_steps': 100000, 'distance_m': 70000, 'active_days': 10, 'event_days': 12,
     'active_pct': 83, 'avg_daily': 8333, 'consistency': 80, 'improvement': 5000,
     'reward_eligible': true, 'flags': []},
    {'profile_id': 'p2', 'account_id': 'a2', 'name': 'A very long participant name that should truncate',
     'email': 'f@example.com', 'sex': null, 'status': 'active', 'total_steps': 23456, 'distance_m': 1,
     'active_days': 2, 'event_days': 12, 'active_pct': 17, 'avg_daily': 1954, 'consistency': 10,
     'improvement': -100, 'reward_eligible': false, 'flags': ['dropout_risk', 'high_values']},
    {'profile_id': 'p3', 'account_id': 'a3', 'name': 'Zero', 'email': 'z@example.com', 'sex': 'female',
     'status': 'active', 'total_steps': 0, 'distance_m': 0, 'active_days': 0, 'event_days': 12,
     'active_pct': 0, 'avg_daily': 0, 'consistency': 0, 'improvement': 0,
     'reward_eligible': false, 'flags': ['no_data', 'sync_stale']},
  ],
};

Future<void> pump(WidgetTester tester, Widget page,
    {Size size = const Size(420, 4200), double scale = 1, Brightness b = Brightness.light}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      myEventStatsProvider.overrideWith((ref, id) async => stats()),
      eventOverviewProvider.overrideWith((ref, id) async => overview),
      stepTrackingProvider.overrideWith(FakeTracking.new),
      activeProfileProvider.overrideWith((ref) async => profile),
      profilesProvider.overrideWith((ref) async => [profile]),
      staffRoleProvider.overrideWith((ref) async => 'super'),
    ],
    child: MaterialApp(
      theme: b == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true), child: child!),
      home: page,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('progress page shows every section with real numbers', (tester) async {
    await pump(tester, MyEventProgressPage(event: event, now: () => now));
    for (final t in ['Event progress', 'This week', 'Trend', 'Consistency', 'Calendar',
        'Personal bests', 'Milestones', 'Badges', 'Recognition']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('45,000'), findsWidgets); // 7 x 6000 + 2000 + 1000
    expect(find.text('12 of 14'), findsOneWidget); // Nov 2..13
    expect(find.text('Back on track'), findsOneWidget); // 9, 10 missed then 11, 12
    expect(find.text('7 AM'), findsOneWidget); // usual start
    expect(find.textContaining('You currently qualify'), findsOneWidget);
    expect(find.text('7-day streak'), findsOneWidget);
  });

  testWidgets('organizer dashboard: health, highlights, filters and flags', (tester) async {
    final e = WalkEvent(id: 'e1', name: 'Spring', startsOn: DateTime(2026, 11, 2),
        endsOn: DateTime(2026, 11, 15), memberCount: 3);
    await pump(tester, AdminEventDashboardPage(event: e));
    expect(find.text('123K'), findsOneWidget);
    expect(find.text('67%'), findsOneWidget);
    expect(find.textContaining('Mani (100,000 steps)'), findsOneWidget);
    expect(find.text('Needs attention (2)'), findsOneWidget);
    await tester.tap(find.text('No step data (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Zero'), findsOneWidget);
    expect(find.text('Mani'), findsNothing);
  });

  test('participants CSV is ranked and formula-safe', () {
    final csv = participantsCsv('E', [
      {'name': '=evil', 'email': 'x@example.com', 'status': 'active', 'total_steps': 5, 'flags': ['no_data']},
    ]);
    expect(csv, contains('1,"\'=evil"'));
    expect(csv, contains('"no_data"'));
  });

  for (final b in Brightness.values) {
    for (final cfg in [
      (size: const Size(360, 4200), scale: 1.0, name: 'phone'),
      (size: const Size(360, 8400), scale: 2.0, name: 'phone, text x2'),
      (size: const Size(1024, 3400), scale: 1.0, name: 'tablet'),
    ]) {
      testWidgets('no overflow: progress + admin dashboard, ${cfg.name} / ${b.name}', (tester) async {
        await pump(tester, MyEventProgressPage(event: event, now: () => now),
            size: cfg.size, scale: cfg.scale, b: b);
        expect(tester.takeException(), isNull);
        await pump(tester,
            AdminEventDashboardPage(event: WalkEvent(id: 'e1', name: 'Spring',
                startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 15), memberCount: 3)),
            size: cfg.size, scale: cfg.scale, b: b);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
