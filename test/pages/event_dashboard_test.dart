import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:walkathan/features/activity/history_math.dart';
import 'package:walkathan/features/activity/step_day.dart';
import 'package:walkathan/features/activity/step_providers.dart';
import 'package:walkathan/features/events/event_models.dart';
import 'package:walkathan/features/events/event_providers.dart';
import 'package:walkathan/models/custom_error.dart';
import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/content/event/event_dashboard_page.dart';
import 'package:walkathan/pages/content/home/home_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/theme/app_theme.dart';

class FakeTracking extends StepTrackingController {
  FakeTracking(this.initial);
  final StepTrackingState initial;
  @override
  Future<StepTrackingState> build() async => initial;
  @override
  Future<void> refresh() async {}
}

final now = DateTime(2026, 11, 14, 9);
const profile = WalkerProfile(
    id: 'p2', accountId: 'a1', relation: ProfileRelation.self,
    displayName: 'Asha', dailyGoal: 8000);

final active = MemberEvent(
    id: 'e1', name: 'Spring Walkathon',
    startsOn: DateTime(2026, 11, 10), endsOn: DateTime(2026, 11, 19));
final upcoming = MemberEvent(
    id: 'e2', name: 'Winter Walkathon',
    startsOn: DateTime(2026, 12, 1), endsOn: DateTime(2026, 12, 31));

BoardRow row(int rank, String id, String name, int steps, {bool mine = false}) =>
    BoardRow(rank: rank, profileId: id, name: name, steps: steps, mine: mine);

EventBoard fullBoard() => EventBoard(
      walkers: 6, activeWalkers: 5, totalSteps: 1234567,
      rows: [
        row(1, 'p1', 'Bala', 52000),
        row(2, 'p2', 'Asha', 48100, mine: true),
        row(3, 'p3', 'A very long walker name that must truncate', 30000),
        row(4, 'p4', 'Dev', 12000),
        row(5, 'p5', 'Esha', 800),
      ],
      mine: [
        row(2, 'p2', 'Asha', 48100, mine: true),
        row(6, 'p6', 'Asha Jr', 0, mine: true),
      ],
    );

Future<void> pump(
  WidgetTester tester,
  Widget page, {
  List<MemberEvent>? events,
  Future<EventBoard> Function(BoardKey key)? board,
  Future<List<MemberEvent>> Function()? loadEvents,
  Size size = const Size(420, 2000),
  Brightness brightness = Brightness.light,
  double textScale = 1,
  int todaySteps = 4200,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    retry: (count, error) => null,
    overrides: <Override>[
      myEventsProvider.overrideWith(
          (ref) => (loadEvents ?? () async => events ?? [active, upcoming])()),
      eventBoardProvider.overrideWith(
          (ref, key) => (board ?? (k) async => fullBoard())(key)),
      activeProfileProvider.overrideWith((ref) async => profile),
      profilesProvider.overrideWith((ref) async => [profile]),
      stepTrackingProvider.overrideWith(() => FakeTracking(StepTrackingState(
          today: StepDay(
              localDate: '2026-11-14', offsetMin: 180,
              source: StepSourceKind.healthStore, steps: todaySteps)))),
      activityHistoryProvider.overrideWith((ref) async => const ActivityHistory(
          days: {'2026-11-13': DayRecord(steps: 9000), '2026-11-12': DayRecord(steps: 8500)},
          restDays: {}, goal: 8000)),
    ],
    child: MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: true),
          child: child!),
      home: page,
    ),
  ));
  await tester.pumpAndSettle();
  // with animations off nothing schedules frames while futures resolve
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  final dashboard = EventDashboardPage(now: () => now);

  testWidgets('shows event status, stats, podium, list and my other profile',
      (tester) async {
    await pump(tester, dashboard);
    expect(find.text('Spring Walkathon'), findsOneWidget);
    expect(find.text('Day 5 of 10 · 5 days left'), findsOneWidget);
    expect(find.text('walkers'), findsOneWidget);
    expect(find.text('6'), findsWidgets);
    expect(find.text('1.23M'), findsOneWidget);
    expect(find.text('#2'), findsWidgets); // my best rank (strip + standing)
    // podium: top three by name; list starts at rank 4
    expect(find.text('Bala'), findsOneWidget);
    expect(find.text('52,000'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Rank 4, Dev, 12,000 steps')), findsOneWidget);
    // my second profile is outside the listed rows -> shown separately
    expect(find.text('Your household'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Rank 6, Asha Jr, you')), findsOneWidget);
  });

  testWidgets('period switch asks for that period', (tester) async {
    final asked = <BoardPeriod>[];
    await pump(tester, dashboard, board: (k) async {
      asked.add(k.period);
      return fullBoard();
    });
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('This week'));
    await tester.pumpAndSettle();
    expect(asked, containsAll([BoardPeriod.event, BoardPeriod.day, BoardPeriod.week]));
  });

  testWidgets('several events: the header opens a picker and switching works',
      (tester) async {
    await pump(tester, dashboard);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^Switch event')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Winter Walkathon'));
    await tester.pumpAndSettle();
    expect(find.textContaining('starts in 17 days'), findsOneWidget);
    expect(find.textContaining('The board opens on Dec 1'), findsOneWidget);
  });

  testWidgets('a single event has no switcher', (tester) async {
    await pump(tester, dashboard, events: [active]);
    expect(find.bySemanticsLabel(RegExp(r'^Switch event')), findsNothing);
  });

  testWidgets('no event: explains what happens next', (tester) async {
    await pump(tester, dashboard, events: []);
    expect(find.text('You\'re not on an event yet'), findsOneWidget);
    expect(find.textContaining('administrator adds members'), findsOneWidget);
  });

  testWidgets('nobody has walked yet', (tester) async {
    await pump(tester, dashboard,
        board: (k) async => EventBoard(
            walkers: 3, activeWalkers: 0, totalSteps: 0,
            rows: [row(1, 'p1', 'Bala', 0), row(1, 'p2', 'Asha', 0, mine: true)],
            mine: [row(1, 'p2', 'Asha', 0, mine: true)]));
    expect(find.text('No steps yet'), findsOneWidget);
  });

  testWidgets('fewer than three walkers: plain list, no podium', (tester) async {
    await pump(tester, dashboard,
        board: (k) async => EventBoard(
            walkers: 2, activeWalkers: 2, totalSteps: 300,
            rows: [row(1, 'p1', 'Bala', 200), row(2, 'p2', 'Asha', 100, mine: true)],
            mine: [row(2, 'p2', 'Asha', 100, mine: true)]));
    expect(find.bySemanticsLabel(RegExp(r'^Rank 1, Bala, 200 steps')), findsOneWidget);
    expect(find.text('Your household'), findsNothing);
  });

  testWidgets('board failure shows retry but keeps the event header', (tester) async {
    await pump(tester, dashboard,
        board: (k) async => throw const CustomError(message: 'Network down'));
    expect(find.text('Spring Walkathon'), findsOneWidget);
    expect(find.text('Network down'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('events failure shows a retry state', (tester) async {
    await pump(tester, dashboard,
        loadEvents: () async => throw const CustomError(message: 'Offline'));
    expect(find.text('Offline'), findsOneWidget);
  });

  group('Home', () {
    final home = HomePage(now: () => now);

    testWidgets('greets, shows today, event standing and streak', (tester) async {
      await pump(tester, home);
      expect(find.text('Good morning, Asha'), findsOneWidget);
      expect(find.text('4,200'), findsOneWidget);
      expect(find.text('3,800 to go of 8,000'), findsOneWidget);
      expect(find.text('Spring Walkathon'), findsOneWidget);
      expect(find.text('#2 of 6 · 48,100 steps'), findsOneWidget);
      expect(find.text('Streak: 2 days (best 2)'), findsOneWidget);
    });

    testWidgets('goal reached and no event', (tester) async {
      await pump(tester, home, events: [], todaySteps: 9100);
      expect(find.text('Goal of 8,000 reached'), findsOneWidget);
      expect(find.textContaining('not on an event yet'), findsOneWidget);
      expect(find.text('Streak: 3 days (best 3)'), findsOneWidget);
    });
  });

  for (final b in Brightness.values) {
    for (final cfg in [
      (size: const Size(360, 2400), scale: 1.0, name: 'phone'),
      (size: const Size(360, 3600), scale: 2.0, name: 'phone, text x2'),
      (size: const Size(1024, 1600), scale: 1.0, name: 'tablet'),
    ]) {
      testWidgets('no overflow: dashboard + home, ${cfg.name} / ${b.name}',
          (tester) async {
        await pump(tester, dashboard,
            size: cfg.size, brightness: b, textScale: cfg.scale);
        expect(tester.takeException(), isNull);
        await pump(tester, HomePage(now: () => now),
            size: cfg.size, brightness: b, textScale: cfg.scale);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
