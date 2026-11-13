// Renders the shared UI components across phone/tablet sizes, light/dark
// themes and large text scale. Any RenderFlex overflow or build exception
// fails the test.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:walkathan/models/custom_error.dart';
import 'package:walkathan/pages/content/leader_board/leaderboard_widgets.dart';
import 'package:walkathan/pages/widgets/auth_layout.dart';
import 'package:walkathan/pages/widgets/buttons.dart';
import 'package:walkathan/pages/widgets/form_fields.dart';
import 'package:walkathan/pages/widgets/state_widgets.dart';
import 'package:walkathan/theme/app_theme.dart';

const _sizes = <String, Size>{
  'phone': Size(360, 640),
  'tablet': Size(1024, 768),
};

final _entries = <Map<String, dynamic>>[
  {'userId': 'a', 'name': 'A very long display name that must truncate', 'totalSteps': 1234567},
  {'userId': 'b', 'name': 'Bea', 'totalSteps': 9000},
  {'userId': 'c', 'name': 'Cy', 'totalSteps': 12},
  {'userId': 'd', 'name': 'Dee', 'totalSteps': 0},
  {'userId': 'e', 'name': 'Eli', 'totalSteps': 0},
];

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Size size,
  required Brightness brightness,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: brightness == Brightness.light
            ? AppTheme.light()
            : AppTheme.dark(),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: app!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final sizeEntry in _sizes.entries) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        final label =
            '${sizeEntry.key} / ${brightness.name} / text x$scale';

        testWidgets('auth layout + form fields: $label', (tester) async {
          await _pump(
            tester,
            AuthLayout(
              title: 'Create your account',
              subtitle: 'Join the walk and see where you rank.',
              children: [
                NameFormField(nameController: TextEditingController()),
                const SizedBox(height: 16),
                EmailFormField(emailController: TextEditingController()),
                const SizedBox(height: 16),
                PasswordFormField(
                  passwordController: TextEditingController(),
                  labelText: 'Password',
                ),
                const SizedBox(height: 16),
                AppButton(label: 'Sign Up', onPressed: () {}),
                AppButton(label: 'Sign Up', loading: true, onPressed: () {}),
                AuthFooter(
                  prompt: 'Already a member?',
                  action: AppTextButton(label: 'Sign in', onPressed: () {}),
                ),
              ],
            ),
            size: sizeEntry.value,
            brightness: brightness,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Create your account'), findsOneWidget);
        });

        testWidgets('leaderboard section states: $label', (tester) async {
          final states = <AsyncValue<List<Map<String, dynamic>>>>[
            AsyncData(_entries),
            const AsyncData([]),
            const AsyncLoading(),
            AsyncError(
              const CustomError(message: 'boom'),
              StackTrace.empty,
            ),
          ];
          await _pump(
            tester,
            Scaffold(
              body: ListView(
                children: [
                  for (final s in states)
                    LeaderboardSection(
                      title: 'Top Men',
                      icon: Icons.emoji_events,
                      state: s,
                      currentUserId: 'b',
                      onRetry: () {},
                    ),
                ],
              ),
            ),
            size: sizeEntry.value,
            brightness: brightness,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('You'), findsNothing); // inside Text.rich span
        });

        testWidgets('state messages: $label', (tester) async {
          await _pump(
            tester,
            Scaffold(
              body: ErrorState(message: 'Network down', onRetry: () {}),
            ),
            size: sizeEntry.value,
            brightness: brightness,
            textScale: scale,
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Try again'), findsOneWidget);
        });
      }
    }
  }
}
