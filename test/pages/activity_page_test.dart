import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:walkathan/features/activity/history_math.dart';
import 'package:walkathan/features/activity/step_day.dart';
import 'package:walkathan/features/activity/step_providers.dart';
import 'package:walkathan/models/custom_error.dart';
import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/content/activity/activity_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/theme/app_theme.dart';

class FakeController extends StepTrackingController {
  FakeController(this.initial);
  final StepTrackingState initial;
  @override
  Future<StepTrackingState> build() async => initial;
  @override
  Future<void> refresh() async {}
}

const profile = WalkerProfile(
    id: 'p1', accountId: 'a1', relation: ProfileRelation.self,
    displayName: 'Priya', dailyGoal: 8000);

// Friday; week is Mon 9 .. Sun 15 Nov 2026.
final now = DateTime(2026, 11, 13, 14);

ActivityHistory history() => ActivityHistory(
      days: const {
        '2026-11-09': DayRecord(steps: 9000, distanceM: 6300, kcal: 360),
        '2026-11-10': DayRecord(steps: 8200, distanceM: 5700, kcal: 330),
        '2026-11-11': DayRecord(steps: 12000, distanceM: 8400, kcal: 480),
        '2026-11-13': DayRecord(steps: 3000, distanceM: 2100, kcal: 120),
        '2026-10-20': DayRecord(steps: 21000, distanceM: 14700, kcal: 840),
      },
      restDays: const {'2026-11-12'},
      goal: 8000,
    );

Future<void> pump(
  WidgetTester tester, {
  Future<ActivityHistory?> Function()? load,
  StepTrackingState live = const StepTrackingState(),
  Size size = const Size(420, 3200),
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      activityHistoryProvider.overrideWith((ref) => (load ?? () async => history())()),
      stepTrackingProvider.overrideWith(() => FakeController(live)),
      activeProfileProvider.overrideWith((ref) async => profile),
      profilesProvider.overrideWith((ref) async => [profile]),
    ],
    child: MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale), disableAnimations: true),
          child: child!),
      home: ActivityPage(now: () => now),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('week view: total, average, streak with rest day, recaps, records',
      (tester) async {
    await pump(tester);
    expect(find.text('Nov 9 – Nov 15'), findsOneWidget);
    expect(find.text('32,200'), findsWidgets); // 9000+8200+12000+3000
    expect(find.textContaining('a day on average'), findsOneWidget);
    // 9, 10, 11 met; 12 is a rest day; today (13) not met yet -> streak 3
    expect(find.text('Current streak: 3 days'), findsOneWidget);
    expect(find.textContaining('rest days this week 1/2'), findsOneWidget);
    expect(find.text('November 2026 recap'), findsOneWidget);
    expect(find.text('2026 recap'), findsOneWidget);
    expect(find.text('Personal records'), findsOneWidget);
    expect(find.text('21,000'), findsWidgets); // best day (October)
    expect(find.textContaining('Achievements ·'), findsOneWidget);
    expect(find.text('10K day'), findsOneWidget);
  });

  testWidgets('live count for today overlays server history', (tester) async {
    await pump(tester,
        live: StepTrackingState(
            today: StepDay(
                localDate: '2026-11-13', offsetMin: 180,
                source: StepSourceKind.healthStore, steps: 8500)));
    // today now meets the goal -> streak grows to 4
    expect(find.text('Current streak: 4 days'), findsOneWidget);
  });

  testWidgets('switching period and navigating back; cannot go into the future',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(find.text('November 2026'), findsWidgets);

    final next = find.widgetWithIcon(IconButton, Icons.chevron_right);
    expect(tester.widget<IconButton>(next).onPressed, isNull,
        reason: 'no future periods');

    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('October 2026'), findsWidgets);
    expect(find.text('October 2026 recap'), findsOneWidget);
    expect(tester.widget<IconButton>(next).onPressed, isNotNull);

    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.text('2026'), findsWidgets);
    await tester.tap(find.text('Day'));
    await tester.pumpAndSettle();
    expect(find.textContaining('goal 8,000'), findsOneWidget);
  });

  testWidgets('tapping today offers a rest day; past days do not', (tester) async {
    await pump(tester);
    await tester.tap(find.bySemanticsLabel(RegExp(r'^November 13:')));
    await tester.pumpAndSettle();
    expect(find.text('Make this a rest day'), findsOneWidget);
    Navigator.of(tester.element(find.text('Make this a rest day'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(RegExp(r'^November 10:')));
    await tester.pumpAndSettle();
    expect(find.text('8,200 steps'), findsOneWidget);
    expect(find.text('Make this a rest day'), findsNothing);
  });

  testWidgets('empty history shows zeros and friendly recap text', (tester) async {
    await pump(tester,
        load: () async =>
            const ActivityHistory(days: {}, restDays: {}, goal: 8000));
    expect(find.text('Current streak: 0 days'), findsOneWidget);
    expect(find.text('No steps recorded in this period yet.'), findsNWidgets(2));
  });

  testWidgets('load failure shows a retry state', (tester) async {
    await pump(tester,
        load: () async => throw const CustomError(message: 'Network down'));
    expect(find.text('Network down'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    for (final cfg in [
      (size: const Size(360, 3600), scale: 1.0, name: 'phone'),
      (size: const Size(360, 5200), scale: 2.0, name: 'phone, text x2'),
      (size: const Size(1024, 2400), scale: 1.0, name: 'tablet'),
    ]) {
      testWidgets('no layout overflow: ${cfg.name} / ${b.name}', (tester) async {
        await pump(tester, size: cfg.size, brightness: b, textScale: cfg.scale);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Month'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Year'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
