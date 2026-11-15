import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:walkathan/features/login/login_gate.dart';
import 'package:walkathan/features/transfer/transfer_models.dart';
import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/admin/admin_event_dashboard_page.dart';
import 'package:walkathan/pages/admin/count_tools.dart';
import 'package:walkathan/pages/admin/event_reset_switch.dart';
import 'package:walkathan/pages/admin/transfer_approvals_page.dart';
import 'package:walkathan/pages/auth/device/device_gate_page.dart';
import 'package:walkathan/pages/auth/device/select_profile_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/repositories/admin_repository.dart';
import 'package:walkathan/repositories/transfer_repository.dart';
import 'package:walkathan/theme/app_theme.dart';

class FakeGate extends LoginGate {
  FakeGate(this.initial);
  final LoginGateState initial;
  String? chosen;
  int rechecks = 0, asks = 0;

  @override
  LoginGateState build() => initial;
  @override
  Future<void> recheck() async => rechecks++;
  @override
  Future<void> askAgain() async => asks++;
  @override
  Future<void> choose(String profileId) async => chosen = profileId;
}

class FakeAdmin extends AdminRepository {
  final calls = <String>[];
  bool ok = true;
  @override
  Future<int> resetCounts(String eventId, {String? profileId, required String note}) async {
    calls.add('reset:$eventId:${profileId ?? 'all'}:$note');
    return profileId == null ? 4 : 1;
  }

  @override
  Future<Map<String, dynamic>> validateCounts(String eventId, {bool repair = false}) async {
    if (repair) calls.add('repair');
    return {
      'ok': ok || repair,
      'repaired': repair,
      'checks': [
        {'check': 'daily_totals_match_sources', 'ok': ok || repair, 'mismatches': ok || repair ? 0 : 2,
         'sample': ok || repair ? [] : [{'profile_id': 'p1', 'sources_say': 100, 'stored': 4753}]},
        {'check': 'event_total_vs_participant_list', 'ok': true, 'event_days_total': 10, 'participant_list_total': 10},
      ],
    };
  }
}

class FakeTransfers extends TransferRepository {
  final decided = <String>[];
  @override
  Future<bool> isReviewer() async => true;
  @override
  Future<List<TransferReview>> review({String? status = 'pending'}) async => [];
  @override
  Future<List<DeviceRequest>> deviceRequests({String? status = 'pending'}) async => status == null
      ? []
      : [
          DeviceRequest(
              accountId: 'a1',
              deviceId: 'phone-0001',
              email: 'newphone@example.com',
              label: 'iPhone',
              deviceTail: '0001',
              status: TransferStatus.pending,
              requestedAt: DateTime(2026, 11, 1),
              otherPhones: 1,
              ownRequest: false),
        ];
  @override
  Future<String> decideDevice(DeviceRequest d, {required bool approve, String? note}) async {
    decided.add('${d.email}:${approve ? 'approve' : 'reject'}');
    return approve ? 'approved' : 'rejected';
  }
}

Future<void> pump(WidgetTester tester, Widget home, List<Override> overrides) async {
  tester.view.physicalSize = const Size(420, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.light(),
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(disableAnimations: true), child: child!),
      home: home,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

const p1 = WalkerProfile(id: 'p1', accountId: 'a', relation: ProfileRelation.self, displayName: 'Anu');
const p2 = WalkerProfile(id: 'p2', accountId: 'a', relation: ProfileRelation.child, displayName: 'Ravi');

void main() {
  resetSwitchTests();
  dashboardResetTests();
  group('new phone gate', () {
    testWidgets('a new phone waits for approval and can re-check or sign out', (tester) async {
      final gate = FakeGate(const LoginGateState(LoginStage.devicePending));
      await pump(tester, const DeviceGatePage(), [loginGateProvider.overrideWith(() => gate)]);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.textContaining('new phone'), findsOneWidget);
      await tester.tap(find.text('Check again'));
      expect(gate.rechecks, 1);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('a rejected phone shows the approver\'s note and can ask again', (tester) async {
      final gate = FakeGate(const LoginGateState(LoginStage.deviceRejected, note: 'not your phone'));
      await pump(tester, const DeviceGatePage(), [loginGateProvider.overrideWith(() => gate)]);
      expect(find.text('Phone not approved'), findsOneWidget);
      expect(find.textContaining('not your phone'), findsOneWidget);
      await tester.tap(find.text('Ask again'));
      expect(gate.asks, 1);
    });

    testWidgets('offline on a never-approved phone says so', (tester) async {
      await pump(tester, const DeviceGatePage(),
          [loginGateProvider.overrideWith(() => FakeGate(const LoginGateState(LoginStage.deviceError)))]);
      expect(find.text('Can\'t reach the server'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('profile selection lists everyone and picks the tapped one', (tester) async {
      final gate = FakeGate(const LoginGateState(LoginStage.chooseProfile));
      await pump(tester, const SelectProfilePage(), [
        loginGateProvider.overrideWith(() => gate),
        profilesProvider.overrideWith((ref) async => [p1, p2]),
        activeProfileProvider.overrideWith((ref) async => p1),
      ]);
      expect(find.text('Who is walking on this phone?'), findsOneWidget);
      expect(find.text('Anu'), findsOneWidget);
      expect(find.textContaining('last used'), findsOneWidget);
      await tester.tap(find.text('Ravi'));
      await tester.pump();
      expect(gate.chosen, 'p2');
    });
  });

  group('approvals: new phones', () {
    testWidgets('an organizer approves a new phone', (tester) async {
      final repo = FakeTransfers();
      await pump(tester, const TransferApprovalsPage(), [
        transferRepositoryProvider.overrideWithValue(repo),
        staffRoleProvider.overrideWith((ref) async => 'organizer'),
      ]);
      expect(find.text('New phones'), findsOneWidget);
      await tester.tap(find.text('New phones'));
      await tester.pumpAndSettle();
      expect(find.text('newphone@example.com'), findsOneWidget);
      expect(find.textContaining('1 other approved phone'), findsOneWidget);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Approve').last); // the dialog's
      await tester.pumpAndSettle();
      expect(repo.decided, ['newphone@example.com:approve']);
    });
  });

  group('count tools', () {
    Future<FakeAdmin> openReset(WidgetTester tester, {String? profileId}) async {
      final admin = FakeAdmin();
      await pump(
        tester,
        Consumer(builder: (c, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => confirmResetCounts(c, ref,
                      eventId: 'e1', eventName: 'Spring', profileId: profileId, profileName: 'Anu'),
                  child: const Text('open'),
                ),
              ),
            )),
        [adminRepositoryProvider.overrideWithValue(admin)],
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));
      return admin;
    }

    testWidgets('reset needs a reason, then zeroes everyone', (tester) async {
      final admin = await openReset(tester);
      expect(find.text('Set ALL counts to zero?'), findsOneWidget);
      FilledButton go() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Set to zero'));
      expect(go().onPressed, isNull, reason: 'a reason is required');
      await tester.enterText(find.byType(TextField), 'fresh start');
      await tester.pump();
      expect(go().onPressed, isNotNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Set to zero'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(admin.calls, ['reset:e1:all:fresh start']);
      expect(find.text('Reset 4 profiles to zero.'), findsOneWidget);
    });

    testWidgets('reset of one profile names them and targets them', (tester) async {
      final admin = await openReset(tester, profileId: 'p1');
      expect(find.text('Set Anu to zero?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'wrong data');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Set to zero'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(admin.calls, ['reset:e1:p1:wrong data']);
    });

    testWidgets('verify page shows a clean result', (tester) async {
      await pump(tester, const VerifyCountsPage(eventId: 'e1', eventName: 'Spring'), [
        adminRepositoryProvider.overrideWithValue(FakeAdmin()),
        staffRoleProvider.overrideWith((ref) async => 'super'),
      ]);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('matches the raw readings'), findsOneWidget);
      expect(find.text('Repair totals'), findsNothing);
    });

    testWidgets('verify page flags a mismatch and repairs it', (tester) async {
      final admin = FakeAdmin()..ok = false;
      await pump(tester, const VerifyCountsPage(eventId: 'e1', eventName: 'Spring'), [
        adminRepositoryProvider.overrideWithValue(admin),
        staffRoleProvider.overrideWith((ref) async => 'super'),
      ]);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Some counts do not match. See below.'), findsOneWidget);
      expect(find.text('2 found'), findsOneWidget);
      await tester.tap(find.text('Repair totals'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Repair'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(admin.calls, ['repair']);
      debugPrint('DUMP ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' | ')}');
      expect(find.textContaining('Repaired'), findsOneWidget);
    });
  });
}

// ---- reproduces the dashboard flow: menu -> dialog -> reset -> refresh
void dashboardResetTests() {
  testWidgets('dashboard: Set ALL counts to zero runs without framework errors', (tester) async {
    final admin = FakeAdmin();
    var loads = 0;
    final event = WalkEvent(
        id: 'e1', name: 'Spring', startsOn: DateTime(2026, 11, 2), endsOn: DateTime(2026, 11, 15), memberCount: 1);
    await pump(tester, AdminEventDashboardPage(event: event), [
      adminRepositoryProvider.overrideWithValue(admin),
      staffRoleProvider.overrideWith((ref) async => 'super'),
      isTransferReviewerProvider.overrideWith((ref) async => true),
      eventOverviewProvider.overrideWith((ref, id) async {
        loads++;
        return {
          'event': {'status': 'published'},
          'participants': 1, 'active_participants': 1, 'active_today': 1,
          'total_steps': loads == 1 ? 4753 : 0, 'total_distance_m': 0, 'synced_48h_pct': 100,
          'reward_eligible': 0, 'last_board_update': '2026-11-13T09:00:00Z',
          'daily': [], 'participants_detail': [],
        };
      }),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Count tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set ALL counts to zero…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'fresh start');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Set to zero'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(admin.calls, ['reset:e1:all:fresh start']);
    expect(loads, 2, reason: 'the dashboard must reload after a reset');
  });
}

void resetSwitchTests() {
  Map<String, dynamic> overview(int resetCount) => {
        'participants_detail': [
          for (var i = 0; i < 3; i++)
            {'profile_id': 'p$i', 'name': 'P$i', 'reset_on': i < resetCount ? '2026-11-15' : null},
        ],
      };

  testWidgets('switch is off when counts are live; turning it on resets everyone', (tester) async {
    final admin = FakeAdmin();
    var resetCount = 0;
    await pump(
      tester,
      const Scaffold(body: EventResetSwitch(eventId: 'e1', eventName: 'Spring')),
      [
        adminRepositoryProvider.overrideWithValue(admin),
        eventOverviewProvider.overrideWith((ref, id) async => overview(resetCount)),
      ],
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.textContaining('counts are live'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Set ALL counts to zero?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'new season');
    await tester.pump();
    resetCount = 3; // what the server reports after the reset
    await tester.tap(find.widgetWithText(FilledButton, 'Set to zero'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(admin.calls, ['reset:e1:all:new season']);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('all 3 profiles count from zero'), findsOneWidget);
  });

  testWidgets('cancelling the confirmation leaves the switch off and resets nothing', (tester) async {
    final admin = FakeAdmin();
    await pump(
      tester,
      const Scaffold(body: EventResetSwitch(eventId: 'e1', eventName: 'Spring')),
      [
        adminRepositoryProvider.overrideWithValue(admin),
        eventOverviewProvider.overrideWith((ref, id) async => overview(0)),
      ],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(admin.calls, isEmpty);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('a partly reset event shows off and says how many', (tester) async {
    await pump(
      tester,
      const Scaffold(body: EventResetSwitch(eventId: 'e1', eventName: 'Spring')),
      [
        adminRepositoryProvider.overrideWithValue(FakeAdmin()),
        eventOverviewProvider.overrideWith((ref, id) async => overview(1)),
      ],
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.textContaining('1 of 3 profiles'), findsOneWidget);
  });
}
