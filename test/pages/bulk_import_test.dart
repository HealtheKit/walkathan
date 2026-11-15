import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:walkathan/features/admin/member_csv.dart';
import 'package:walkathan/pages/admin/admin_events_page.dart';
import 'package:walkathan/providers/profile_providers.dart';
import 'package:walkathan/repositories/admin_repository.dart';
import 'package:walkathan/theme/app_theme.dart';

class FakeAdmin extends AdminRepository {
  final List<List<MemberRow>> chunks = [];
  bool failSecondChunk = false;

  @override
  Future<List<ImportOutcome>> bulkImportChunk(String eventId, List<MemberRow> rows) async {
    chunks.add(rows);
    if (failSecondChunk && chunks.length == 2) throw Exception('network');
    return [
      for (final r in rows)
        r.email.startsWith('old')
            ? ImportOutcome(email: r.email, status: 'existing')
            : ImportOutcome(email: r.email, status: 'created', tempPassword: 'Tmp-${r.email.length}'),
    ];
  }
}

final event = WalkEvent(
    id: 'e1', name: 'Spring Walkathon',
    startsOn: DateTime(2027, 3, 1), endsOn: DateTime(2027, 3, 31), memberCount: 0);

void main() {
  group('importInChunks', () {
    List<MemberRow> rows(int n) =>
        [for (var i = 0; i < n; i++) MemberRow(email: 'u$i@example.com', displayName: 'U$i')];

    test('splits into chunks of 50 and reports progress', () async {
      final fake = FakeAdmin();
      final progress = <int>[];
      final out = await importInChunks(
          rows: rows(120),
          send: (c) => fake.bulkImportChunk('e1', c),
          onProgress: (d, t) => progress.add(d));
      expect(fake.chunks.map((c) => c.length), [50, 50, 20]);
      expect(progress, [50, 100, 120]);
      expect(out.length, 120);
      expect(out.every((o) => o.status == 'created'), isTrue);
    });

    test('a failed chunk marks only its rows as errors and continues', () async {
      final fake = FakeAdmin()..failSecondChunk = true;
      final out = await importInChunks(
          rows: rows(120), send: (c) => fake.bulkImportChunk('e1', c));
      expect(out.where((o) => o.status == 'error').length, 50);
      expect(out.where((o) => o.status == 'created').length, 70);
      expect(fake.chunks.length, 3);
    });
  });

  testWidgets('paste, check, import, then show one-time passwords', (tester) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeAdmin();
    await tester.pumpWidget(ProviderScope(
      overrides: [adminRepositoryProvider.overrideWithValue(fake)],
      child: MaterialApp(theme: AppTheme.light(), home: BulkImportPage(event: event)),
    ));

    await tester.enterText(find.byType(TextField),
        'email,name\nnew1@example.com,New One\nold@example.com\nnot-an-email\nnew1@example.com\n');
    await tester.tap(find.text('Check list'));
    await tester.pump();

    expect(find.text('2 valid emails'), findsOneWidget);
    expect(find.text('1 duplicate line ignored'), findsOneWidget);
    expect(find.text('1 line will be skipped:'), findsOneWidget);
    expect(find.text('Line 4: not-an-email'), findsOneWidget);

    await tester.tap(find.text('Import 2 members'));
    await tester.pumpAndSettle();

    expect(fake.chunks.single.map((r) => r.email), ['new1@example.com', 'old@example.com']);
    expect(find.text('Import finished'), findsOneWidget);
    expect(find.text('1 new account created'), findsOneWidget);
    expect(find.text('1 existing account added to the event'), findsOneWidget);
    expect(find.textContaining('shown only now'), findsOneWidget);
    expect(find.textContaining('new1@example.com   Tmp-'), findsOneWidget);
    expect(find.text('Copy all as CSV'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nothing valid: the import button is disabled', (tester) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeAdmin();
    await tester.pumpWidget(ProviderScope(
      overrides: [adminRepositoryProvider.overrideWithValue(fake)],
      child: MaterialApp(theme: AppTheme.light(), home: BulkImportPage(event: event)),
    ));
    await tester.enterText(find.byType(TextField), 'nope\nalso nope');
    await tester.tap(find.text('Check list'));
    await tester.pump();
    expect(find.text('0 valid emails'), findsOneWidget);
    await tester.tap(find.text('Import 0 members'));
    await tester.pump();
    expect(fake.chunks, isEmpty);
  });
}
