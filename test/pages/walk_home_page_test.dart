import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/activity/movement_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:walkathan/features/activity/step_day.dart';
import 'package:walkathan/features/activity/step_providers.dart';
import 'package:walkathan/features/activity/step_source.dart';
import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/content/walk_home/walk_home_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/theme/app_theme.dart';

class FakeController extends StepTrackingController {
  FakeController(this.initial);
  final StepTrackingState initial;
  int permissionRequests = 0;

  @override
  Future<StepTrackingState> build() async => initial;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> requestPermissions() async => permissionRequests++;
}

StepDay day(int steps, {int? floors, int excluded = 0}) => StepDay(
      excludedSteps: excluded,
      localDate: '2026-11-13', offsetMin: 180,
      source: StepSourceKind.healthStore, steps: steps,
      distanceM: 3200, kcal: 150, floors: floors);

const profile = WalkerProfile(
    id: 'p1', accountId: 'a1', relation: ProfileRelation.self,
    displayName: 'Priya', dailyGoal: 8000);

Future<FakeController> pump(
  WidgetTester tester,
  StepTrackingState state, {
  Size size = const Size(400, 1300),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeController(state);
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      stepTrackingProvider.overrideWith(() => fake),
      activeProfileProvider.overrideWith((ref) async => profile),
      profilesProvider.overrideWith((ref) async => [profile]),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const WalkHomePage(userId: 'a1')),
  ));
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  pausedHintTests(pump);
  const ok = {StepSourceKind.healthStore: SourceAvailability.available};

  testWidgets('shows steps, goal, remaining and metrics', (tester) async {
    await pump(tester, StepTrackingState(today: day(4200), sources: ok));
    expect(find.text('4,200'), findsOneWidget);
    expect(find.text('of 8,000 steps'), findsOneWidget);
    expect(find.text('3,800 steps to go'), findsOneWidget);
    expect(find.text('3.20 km'), findsOneWidget);
    expect(find.text('150 kcal'), findsOneWidget);
    expect(find.text('Floors'), findsNothing, reason: 'floors only when reported');
    expect(find.text('Walking as Priya'), findsOneWidget);
  });

  testWidgets('shows the floors tile only when the platform reports floors',
      (tester) async {
    await pump(tester, StepTrackingState(today: day(100, floors: 7), sources: ok));
    expect(find.text('Floors'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('celebrates when the goal is reached', (tester) async {
    await pump(tester, StepTrackingState(today: day(8500), sources: ok));
    expect(find.text('Goal reached. Great walking!'), findsOneWidget);
  });

  testWidgets('no data yet shows zero, not an error', (tester) async {
    await pump(tester, const StepTrackingState(sources: {
      StepSourceKind.healthStore: SourceAvailability.available,
    }));
    expect(find.text('0'), findsOneWidget);
    expect(find.text('8,000 steps to go'), findsOneWidget);
  });

  testWidgets('permission needed: explains and the Allow button requests it',
      (tester) async {
    final fake = await pump(tester, const StepTrackingState(sources: {
      StepSourceKind.healthStore: SourceAvailability.needsPermission,
    }));
    expect(find.text('Allow step access'), findsOneWidget);
    expect(find.textContaining('enter steps by hand'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await tester.pump();
    expect(fake.permissionRequests, 1);
  });

  testWidgets('location not allowed: explains and offers to allow it', (tester) async {
    MovementTracker.instance.status.value = MovementStatus.needsPermission;
    addTearDown(() => MovementTracker.instance.status.value = MovementStatus.off);
    await pump(tester, const StepTrackingState(sources: {
      StepSourceKind.healthStore: SourceAvailability.available,
    }));
    expect(find.text('Count only when you move'), findsOneWidget);
    expect(find.text('Allow location'), findsOneWidget);
    expect(find.textContaining('never uploaded'), findsOneWidget);
  });

  testWidgets('no location prompt when tracking is on or unsupported', (tester) async {
    MovementTracker.instance.status.value = MovementStatus.active;
    addTearDown(() => MovementTracker.instance.status.value = MovementStatus.off);
    await pump(tester, const StepTrackingState(sources: {
      StepSourceKind.healthStore: SourceAvailability.available,
    }));
    expect(find.text('Count only when you move'), findsNothing);
  });

  testWidgets('Health Connect missing is explained', (tester) async {
    await pump(tester, const StepTrackingState(sources: {
      StepSourceKind.healthStore: SourceAvailability.needsHealthConnect,
    }));
    expect(find.text('Health Connect is needed'), findsOneWidget);
    expect(find.text('Open Health Connect'), findsOneWidget);
  });

  testWidgets('unsupported device is explained', (tester) async {
    await pump(tester, const StepTrackingState(sources: {
      StepSourceKind.healthStore: SourceAvailability.unsupported,
    }));
    expect(find.text('Steps unavailable on this device'), findsOneWidget);
  });

  testWidgets('offline: says steps are saved and will upload', (tester) async {
    await pump(tester,
        StepTrackingState(today: day(900), sources: ok, pending: 2, error: 'x'));
    expect(find.textContaining('will upload'), findsOneWidget);
  });

  testWidgets('always explains what counts', (tester) async {
    await pump(tester, StepTrackingState(today: day(900), sources: ok));
    expect(find.textContaining('Only real walking and running on the move count'), findsOneWidget);
    expect(find.textContaining('were ignored'), findsNothing);
  });

  testWidgets('says how many steps were ignored from cycling or machines',
      (tester) async {
    await pump(tester, StepTrackingState(today: day(900, excluded: 1450), sources: ok));
    expect(find.textContaining('1,450 steps were ignored'), findsOneWidget);
  });

  testWidgets('live steps are added to the synced total and marked Live',
      (tester) async {
    await pump(tester,
        StepTrackingState(today: day(4200), sources: ok, liveExtra: 37, live: true));
    expect(find.text('4,237'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
  });

  testWidgets('another profile\'s phone: read-only, own number, no live steps',
      (tester) async {
    await pump(tester, StepTrackingState(
        today: day(1500), liveExtra: 900, live: true,
        otherOwnerProfileId: 'p9', otherOwnerName: 'Ravi'));
    expect(find.text('This phone counts steps for Ravi'), findsOneWidget);
    expect(find.textContaining('never shared or copied'), findsOneWidget);
    expect(find.text('1,500'), findsOneWidget, reason: 'phone steps are not mirrored');
    expect(find.text('Live'), findsNothing);
    expect(find.textContaining('instead'), findsNothing, reason: 'locked: no move offered');
    expect(find.text('Synced from their own phone'), findsOneWidget);
  });

  testWidgets('within the grace period the phone can be switched', (tester) async {
    await pump(tester, StepTrackingState(
        today: day(0), otherOwnerProfileId: 'p9', otherOwnerName: 'Ravi',
        canMoveDevice: true));
    expect(find.text('Use this phone for Priya instead'), findsOneWidget);
  });

  testWidgets('layout holds on a small phone with large numbers', (tester) async {
    await pump(tester, StepTrackingState(today: day(1234567, excluded: 99999), sources: ok),
        size: const Size(360, 640));
    expect(tester.takeException(), isNull);
  });
}

void pausedHintTests(Future<dynamic> Function(WidgetTester, StepTrackingState) pumpPage) {
  testWidgets('a paused count explains itself', (tester) async {
    await pumpPage(
        tester,
        const StepTrackingState(
            pausedNotMoving: true,
            sources: {StepSourceKind.healthStore: SourceAvailability.available}));
    expect(find.textContaining('Steps are paused'), findsOneWidget);
  });

  testWidgets('no pause hint while counting normally', (tester) async {
    await pumpPage(
        tester,
        const StepTrackingState(
            sources: {StepSourceKind.healthStore: SourceAvailability.available}));
    expect(find.textContaining('Steps are paused'), findsNothing);
  });
}
