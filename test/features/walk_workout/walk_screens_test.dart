import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/walk_workout/application/walk_session_controller.dart';
import 'package:walkathan/features/walk_workout/data/mock_services.dart';
import 'package:walkathan/features/walk_workout/domain/walk_models.dart';
import 'package:walkathan/features/walk_workout/presentation/walk_active_page.dart';
import 'package:walkathan/features/walk_workout/presentation/walk_setup_page.dart';
import 'package:walkathan/features/walk_workout/presentation/walk_summary_page.dart';
import 'package:walkathan/features/walk_workout/presentation/walk_ui.dart';
import 'package:walkathan/features/walk_workout/presentation/widgets/walk_status_banner.dart';
import 'package:walkathan/theme/app_theme.dart';

import 'walk_test_support.dart';

/// Records where the walk screens try to go (there is no router in tests).
class FakeNav extends WalkNav {
  final List<String> calls = [];
  @override
  void toSetup(BuildContext context) => calls.add('setup');
  @override
  void toActive(BuildContext context) => calls.add('active');
  @override
  void replaceWithActive(BuildContext context) => calls.add('active');
  @override
  void replaceWithSummary(BuildContext context) => calls.add('summary');
  @override
  void home(BuildContext context) => calls.add('home');
  @override
  void back(BuildContext context) => calls.add('back');
  @override
  void toWalk(BuildContext context, WalkSessionStatus status) => calls.add(
      status == WalkSessionStatus.awaitingSave ? 'summary' : (status.isLive ? 'active' : 'setup'));
}

class Rig {
  Rig({MockLocationService? location, MemoryWorkoutPersistence? store})
      : h = WalkHarness(store: store),
        location = location ?? MockLocationService();
  final WalkHarness h;
  final MockLocationService location;
  final FakeNav nav = FakeNav();
  late final ProviderContainer container = ProviderContainer(overrides: [
    ...h.overrides,
    walkNavProvider.overrideWithValue(nav),
    locationServiceProvider.overrideWithValue(location),
  ]);

  WalkSessionController get c => container.read(walkSessionProvider.notifier);
  WalkSession? get s => container.read(walkSessionProvider);

  void run(int seconds) {
    for (var i = 0; i < seconds; i++) {
      h.now = h.now.add(const Duration(seconds: 1));
      c.tick();
    }
  }

  Future<void> startWalk(WidgetTester tester,
      {WorkoutSettings settings = const WorkoutSettings(autoPause: false),
      WorkoutGoal goal = const WorkoutGoal()}) async {
    await tester.runAsync(() => c.ready);
    c.start(settings: settings, goal: goal);
    c.skipCountdown();
    await tester.pump();
  }

  Future<void> show(WidgetTester tester, Widget page,
      {Size size = const Size(400, 2600), double textScale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(disableAnimations: true, textScaler: TextScaler.linear(textScale)),
            child: child!),
        home: page,
      ),
    ));
    await tester.pump();
  }
}

void main() {
  group('setup', () {
    testWidgets('pick a goal, adjust it, and start', (tester) async {
      final r = Rig();
      await tester.runAsync(() => r.c.ready);
      await r.show(tester, const WalkSetupPage());
      expect(find.text('Start Walk'), findsOneWidget);
      for (final g in ['Open', 'Time', 'Distance', 'Calories', 'Steps']) {
        expect(find.widgetWithText(ChoiceChip, g), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(ChoiceChip, 'Distance'));
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      expect(find.text('3.5'), findsOneWidget);
      expect(find.textContaining('at an easy pace'), findsOneWidget);

      await tester.tap(find.text('Start Walk'));
      await tester.pump();
      expect(r.s!.status, WalkSessionStatus.countingDown);
      expect(r.s!.goal.type, GoalType.distance);
      expect(r.s!.goal.target, 3500, reason: 'stored in metres');
      expect(r.nav.calls, ['active']);
    });

    testWidgets('no location permission: Start is disabled until allowed or GPS is turned off',
        (tester) async {
      final r = Rig(location: MockLocationService(granted: false));
      await tester.runAsync(() => r.c.ready);
      await r.show(tester, const WalkSetupPage());
      await tester.pump();
      FilledButton start() => tester.widget<FilledButton>(
          find.ancestor(of: find.text('Start Walk'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(start().onPressed, isNull);
      expect(find.text('Location permission needed'), findsOneWidget);

      await tester.tap(find.text('Walk without GPS'));
      await tester.pump();
      expect(start().onPressed, isNotNull);
      expect(find.textContaining('estimated from steps'), findsOneWidget);
    });

    testWidgets('starting while a walk exists shows the duplicate dialog and keeps the walk',
        (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(30);
      final id = r.s!.id;
      await r.show(tester, const WalkSetupPage());
      await tester.tap(find.text('Start Walk'));
      await tester.pumpAndSettle();
      expect(find.text('A walk is already in progress.'), findsOneWidget);
      expect(find.text('Return to walk'), findsOneWidget);
      expect(find.text('Finish current walk'), findsOneWidget);
      expect(find.text('Discard current walk'), findsOneWidget);
      await tester.tap(find.text('Return to walk'));
      await tester.pumpAndSettle();
      expect(r.s!.id, id);
      expect(r.nav.calls, ['active']);
    });
  });

  group('active walk', () {
    testWidgets('countdown shows 3 and can be skipped', (tester) async {
      final r = Rig();
      await tester.runAsync(() => r.c.ready);
      r.c.start(settings: const WorkoutSettings(autoPause: false), goal: const WorkoutGoal());
      await r.show(tester, const WalkActivePage());
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Get ready'), findsOneWidget);
      r.run(1);
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.text('Skip countdown'));
      await tester.pump();
      expect(r.s!.status, WalkSessionStatus.tracking);
      expect(find.text('Get ready'), findsNothing);
      expect(find.text('Tracking'), findsOneWidget);
    });

    testWidgets('shows the live metrics', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(600);
      await r.show(tester, const WalkActivePage());
      expect(find.text('00:10:00'), findsOneWidget);
      expect(find.text('0.84'), findsOneWidget); // km
      expect(find.text('1200'), findsOneWidget); // steps
      expect(find.text('110'), findsOneWidget); // bpm
      for (final label in ['DISTANCE', 'PACE', 'CALORIES', 'STEPS', 'HEART RATE', 'SPEED', 'CADENCE', 'ELEVATION']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('11:55'), findsOneWidget, reason: 'pace at 1.4 m/s');
      expect(find.text('avg 11:56'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pause shows the paused state; resume continues', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(60);
      await r.show(tester, const WalkActivePage());
      await tester.tap(find.bySemanticsLabel('Pause walk'));
      await tester.pump();
      expect(r.s!.status, WalkSessionStatus.paused);
      expect(find.text('Paused'), findsWidgets);
      expect(find.textContaining('Paused for'), findsOneWidget);
      r.run(30);
      await tester.pump();
      expect(find.text('00:01:00'), findsOneWidget, reason: 'the active timer is frozen');
      await tester.tap(find.bySemanticsLabel('Resume walk'));
      await tester.pump();
      expect(r.s!.status, WalkSessionStatus.tracking);
    });

    testWidgets('auto-pause explains why', (tester) async {
      final r = Rig();
      await r.startWalk(tester, settings: const WorkoutSettings());
      r.run(20);
      r.h.tracker.speed = 0;
      r.run(12);
      await r.show(tester, const WalkActivePage());
      expect(find.text('Auto-paused'), findsOneWidget);
      expect(find.text('Auto-paused because movement stopped'), findsOneWidget);
    });

    testWidgets('lock blocks the controls until a long press', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(10);
      await r.show(tester, const WalkActivePage());
      await tester.tap(find.byTooltip('Lock screen'));
      await tester.pump();
      expect(find.text('Hold to unlock'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Pause walk'), warnIfMissed: false);
      await tester.pump();
      expect(r.s!.status, WalkSessionStatus.tracking, reason: 'locked: the tap did nothing');
      await tester.longPress(find.text('Hold to unlock'));
      await tester.pump();
      expect(find.text('Hold to unlock'), findsNothing);
    });

    testWidgets('a goal shows progress', (tester) async {
      final r = Rig();
      await r.startWalk(tester, goal: const WorkoutGoal(type: GoalType.distance, target: 1680));
      r.run(600);
      await r.show(tester, const WalkActivePage());
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('Distance goal'), findsOneWidget);
    });

    testWidgets('finish asks first, then goes to the summary', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(120);
      await r.show(tester, const WalkActivePage());
      await tester.tap(find.bySemanticsLabel('Finish walk'));
      await tester.pumpAndSettle();
      expect(find.text('Finish walk?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Finish'));
      await tester.pumpAndSettle();
      expect(r.s!.status, WalkSessionStatus.awaitingSave);
      expect(r.nav.calls, contains('summary'));
    });

    testWidgets('leaving and coming back shows the same walk, still running', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(300);
      await r.show(tester, const WalkActivePage());
      expect(find.text('00:05:00'), findsOneWidget);
      final id = r.s!.id;

      // another screen; the walk screen is destroyed
      await r.show(tester, const Scaffold(body: WalkStatusBanner()));
      expect(find.byType(WalkActivePage), findsNothing);
      r.run(60);

      await r.show(tester, const WalkActivePage());
      expect(find.text('00:06:00'), findsOneWidget);
      expect(r.s!.id, id, reason: 'no second session was created');
      expect(r.s!.distanceM, closeTo(504, 3));
    });

    testWidgets('no walk: offers to start one', (tester) async {
      final r = Rig();
      await tester.runAsync(() => r.c.ready);
      await r.show(tester, const WalkActivePage());
      expect(find.text('No walk in progress'), findsOneWidget);
    });

    for (final cfg in [
      (size: const Size(320, 640), scale: 1.0, name: 'small phone'),
      (size: const Size(360, 800), scale: 2.0, name: 'large text'),
      (size: const Size(430, 932), scale: 1.0, name: 'large phone'),
    ]) {
      testWidgets('no overflow: ${cfg.name}', (tester) async {
        final r = Rig();
        await r.startWalk(tester, goal: const WorkoutGoal(type: GoalType.steps, target: 5000));
        r.run(700);
        r.c.addLap();
        await r.show(tester, const WalkActivePage(), size: cfg.size, textScale: cfg.scale);
        expect(tester.takeException(), isNull);
        await r.show(tester, const WalkSetupPage(), size: cfg.size, textScale: cfg.scale);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('summary', () {
    Future<Rig> finished(WidgetTester tester) async {
      final r = Rig();
      await r.startWalk(tester, goal: const WorkoutGoal(type: GoalType.distance, target: 1000));
      r.h.tracker.speed = 2;
      r.run(300);
      r.c.addLap();
      r.run(300);
      await tester.runAsync(() => r.c.finish());
      return r;
    }

    testWidgets('shows the totals, splits, laps and zones', (tester) async {
      final r = await finished(tester);
      await r.show(tester, const WalkSummaryPage(), size: const Size(400, 4200));
      expect(find.text('Walk summary'), findsOneWidget);
      expect(find.text('1.20'), findsOneWidget); // km
      expect(find.text('10:00'), findsWidgets); // moving time
      expect(find.text('Distance goal reached'), findsOneWidget);
      expect(find.text('Splits (per km)'), findsOneWidget);
      expect(find.text('Laps'), findsOneWidget);
      expect(find.text('Heart-rate zones'), findsOneWidget);
      for (final row in ['Total time', 'Moving time', 'Paused time', 'Average pace', 'Best pace',
          'Average speed', 'Maximum speed', 'Average cadence', 'Average heart rate', 'Elevation gain']) {
        expect(find.text(row), findsOneWidget, reason: row);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('save stores the walk with its title and ends the session', (tester) async {
      final r = await finished(tester);
      await r.show(tester, const WalkSummaryPage(), size: const Size(400, 4200));
      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Evening loop');
      await tester.tap(find.text('Save workout'));
      await tester.pumpAndSettle();
      expect(r.s, isNull);
      expect(r.h.store.workouts.single.session.title, 'Evening loop');
      expect(r.nav.calls, contains('home'));
    });

    testWidgets('discard asks, then removes the walk', (tester) async {
      final r = await finished(tester);
      await r.show(tester, const WalkSummaryPage(), size: const Size(400, 4200));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Discard this walk?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(r.s, isNull);
      expect(r.h.store.workouts, isEmpty);
    });
  });

  group('global walk status', () {
    const host = Scaffold(
        body: Column(children: [WalkStatusBanner(), Expanded(child: Center(child: Text('Some other screen')))]));

    testWidgets('hidden when there is no walk', (tester) async {
      final r = Rig();
      await tester.runAsync(() => r.c.ready);
      await r.show(tester, host);
      expect(find.textContaining('Walk'), findsNothing);
      expect(find.text('Some other screen'), findsOneWidget);
    });

    testWidgets('shows the live walk on another screen and returns to it', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(756);
      await r.show(tester, host);
      expect(find.text('Walk in progress'), findsOneWidget);
      expect(find.textContaining('12:36'), findsOneWidget);
      expect(find.textContaining('1.06 km'), findsOneWidget);
      expect(find.text('Return to Walk'), findsOneWidget);
      await tester.tap(find.text('Walk in progress'));
      expect(r.nav.calls, ['active']);
    });

    testWidgets('pause and resume from another screen', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(60);
      r.c.pause();
      await r.show(tester, host);
      expect(find.text('Walk paused'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pump();
      expect(r.s!.status, WalkSessionStatus.tracking);
      expect(find.text('Walk in progress'), findsOneWidget);
      expect(r.nav.calls, ['active']);
    });

    testWidgets('a finished, unsaved walk asks to be saved or discarded', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(60);
      await tester.runAsync(() => r.c.finish());
      await r.show(tester, host);
      expect(find.text('Walk finished: save or discard'), findsOneWidget);
      await tester.tap(find.text('Review'));
      expect(r.nav.calls, ['summary']);
    });

    testWidgets('the banner goes away after saving, and after discarding', (tester) async {
      final r = Rig();
      await r.startWalk(tester);
      r.run(60);
      await r.show(tester, host);
      expect(find.text('Walk in progress'), findsOneWidget);
      await tester.runAsync(() async {
        await r.c.finish();
        await r.c.save();
      });
      await tester.pump();
      expect(find.textContaining('Walk'), findsNothing);

      r.c.start(settings: const WorkoutSettings(autoPause: false), goal: const WorkoutGoal());
      r.c.skipCountdown();
      await tester.pump();
      expect(find.text('Walk in progress'), findsOneWidget);
      await tester.runAsync(() => r.c.discard());
      await tester.pump();
      expect(find.textContaining('Walk'), findsNothing);
    });

    testWidgets('the tab chip shows the elapsed time while a walk is live', (tester) async {
      final r = Rig();
      await tester.runAsync(() => r.c.ready);
      const tab = Scaffold(body: Center(child: WalkStatusChip(child: Icon(Icons.directions_walk))));
      await r.show(tester, tab);
      expect(find.text('0:00'), findsNothing);
      await r.startWalk(tester);
      r.run(125);
      await tester.pump();
      expect(find.text('2:05'), findsOneWidget);
    });

    testWidgets('after the app is closed and reopened, the banner and the walk are back', (tester) async {
      final store = MemoryWorkoutPersistence();
      final a = Rig(store: store);
      await a.startWalk(tester);
      a.run(300);
      a.c.pause();
      await tester.pump();

      // a brand new app process with the same storage
      final b = Rig(store: store);
      b.h.now = a.h.now.add(const Duration(hours: 2));
      await tester.runAsync(() => b.c.ready);
      await b.show(tester, host);
      expect(find.text('Walk paused'), findsOneWidget);
      expect(find.textContaining('5:00'), findsOneWidget);

      await b.show(tester, const WalkActivePage());
      expect(find.text('00:05:00'), findsOneWidget);
      expect(find.text('Paused'), findsWidgets);
      expect(b.s!.id, a.s!.id);
    });
  });
}
