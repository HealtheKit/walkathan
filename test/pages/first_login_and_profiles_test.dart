import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:walkathan/models/walker_profile.dart';
import 'package:walkathan/pages/auth/welcome/welcome_page.dart';
import 'package:walkathan/pages/content/profiles/profiles_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/repositories/account_repository.dart';
import 'package:walkathan/theme/app_theme.dart';

class _FakeAccount extends AccountRepository {
  _FakeAccount({required this.must});
  final bool must;
  int calls = 0;
  String? lastPassword;

  @override
  bool get mustChangePassword => must;

  @override
  Future<void> completeFirstLogin({String? newPassword}) async {
    calls++;
    lastPassword = newPassword;
  }
}

/// `FilledButton.icon` builds a private subclass, so match with `is`.
Finder _filledButtonWithText(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );

Widget _app(Widget child, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: AppTheme.light(), home: child),
    );

WalkerProfile _p(int i, {ProfileRelation r = ProfileRelation.child}) =>
    WalkerProfile(
      id: 'p$i',
      accountId: 'a',
      relation: i == 0 ? ProfileRelation.self : r,
      displayName: 'Walker $i',
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('WelcomePage (first login)', () {
    testWidgets('requires consent and does not submit without it',
        (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = _FakeAccount(must: false);
      await tester.pumpWidget(
          _app(const WelcomePage(), [accountRepositoryProvider.overrideWithValue(fake)]));

      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(find.text('Please accept to continue'), findsOneWidget);
      expect(fake.calls, 0);
    });

    testWidgets('no password fields when no temporary password was issued',
        (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(const WelcomePage(),
          [accountRepositoryProvider.overrideWithValue(_FakeAccount(must: false))]));
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('temporary password: validates, then submits new password',
        (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = _FakeAccount(must: true);
      await tester.pumpWidget(
          _app(const WelcomePage(), [accountRepositoryProvider.overrideWithValue(fake)]));

      final fields = find.byType(TextFormField);
      expect(fields, findsNWidgets(2));

      // Too short + no consent: nothing is submitted.
      await tester.enterText(fields.at(0), 'abc');
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Password must be at least 6 characters'), findsOneWidget);
      expect(fake.calls, 0);

      // Mismatch is rejected.
      await tester.enterText(fields.at(0), 'secret123');
      await tester.enterText(fields.at(1), 'different');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Passwords not match'), findsOneWidget);
      expect(fake.calls, 0);

      // Valid + consent: submitted once with the new password.
      await tester.enterText(fields.at(1), 'secret123');
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(fake.calls, 1);
      expect(fake.lastPassword, 'secret123');
    });
  });

  group('ProfilesPage', () {
    Future<void> pumpWith(WidgetTester tester, int count) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final list = [for (var i = 0; i < count; i++) _p(i)];
      await tester.pumpWidget(_app(const ProfilesPage(), [
        profilesProvider.overrideWith((ref) async => list),
      ]));
      await tester.pumpAndSettle();
    }

    testWidgets('shows all profiles and an enabled Add button below the cap',
        (tester) async {
      await pumpWith(tester, 3);
      expect(find.text('Walker 0'), findsOneWidget);
      expect(find.text('Walker 2'), findsOneWidget);
      final add = _filledButtonWithText('Add a profile (3/6)');
      expect(add, findsOneWidget);
      expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
    });

    testWidgets('disables Add at 6 profiles with a clear label', (tester) async {
      await pumpWith(tester, 6);
      final add = _filledButtonWithText('Profile limit reached (6/6)');
      expect(add, findsOneWidget);
      expect(tester.widget<FilledButton>(add).onPressed, isNull);
    });
  });
}
