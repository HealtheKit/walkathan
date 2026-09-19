// Basic smoke test for the Walkathan app: boots MyApp (with its required
// ProviderScope/Supabase setup) and verifies it redirects to the sign-in
// page when there is no active session.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:walkathan/config/supabase_config.dart';
import 'package:walkathan/main.dart';
import 'package:walkathan/pages/auth/signin/signin_page.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
    );
  });

  testWidgets('App boots and redirects to sign-in when signed out',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MyApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SigninPage), findsOneWidget);
  });
}
