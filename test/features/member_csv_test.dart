import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/admin/member_csv.dart';

void main() {
  test('parses email-only and email,name lines; skips the header', () {
    final r = parseMemberCsv('email,name\npriya@example.com,Priya K\nsam@example.com\n');
    expect(r.rows.length, 2);
    expect(r.rows[0].email, 'priya@example.com');
    expect(r.rows[0].displayName, 'Priya K');
    expect(r.rows[1].displayName, 'Sam');
    expect(r.issues, isEmpty);
  });

  test('lowercases, trims, strips quotes, accepts ; and tab, handles CRLF and BOM', () {
    final r = parseMemberCsv('﻿"Anu@Example.COM" ; "Anu R"\r\n  ravi@example.com\tRavi  \r\n');
    expect(r.rows.map((e) => e.email), ['anu@example.com', 'ravi@example.com']);
    expect(r.rows[0].displayName, 'Anu R');
    expect(r.rows[1].displayName, 'Ravi');
  });

  test('reports invalid lines with their line number and keeps going', () {
    final r = parseMemberCsv('good@example.com\nnot-an-email\n\n@nope.com\nalso.good@example.com');
    expect(r.rows.length, 2);
    expect(r.issues.map((i) => i.line), [2, 4]);
    expect(r.issues.first.text, 'not-an-email');
  });

  test('duplicates are counted once, case-insensitively', () {
    final r = parseMemberCsv('a@example.com\nA@Example.com\na@example.com,Other');
    expect(r.rows.length, 1);
    expect(r.duplicates, 2);
  });

  test('a first line that is a real email is not mistaken for a header', () {
    expect(parseMemberCsv('email@example.com').rows.length, 1);
  });

  test('empty input gives nothing', () {
    final r = parseMemberCsv('  \n\n');
    expect(r.rows, isEmpty);
    expect(r.issues, isEmpty);
  });

  test('names are capped at 40 characters; name derived from email', () {
    final r = parseMemberCsv('x@example.com,${'N' * 60}');
    expect(r.rows.single.displayName.length, 40);
    expect(nameFromEmail('priya.k_rao-test@example.com'), 'Priya K Rao Test');
  });

  test('credentials CSV quotes cells and neutralises spreadsheet formulas', () {
    final csv = credentialsCsv([
      (email: 'a@example.com', password: 'Abc"123'),
      (email: '=cmd@example.com', password: '+SUM(1)'),
    ]);
    final lines = csv.trim().split('\n');
    expect(lines[0], 'email,temporary_password');
    expect(lines[1], '"a@example.com","Abc""123"');
    expect(lines[2], '"\'=cmd@example.com","\'+SUM(1)"');
  });
}
