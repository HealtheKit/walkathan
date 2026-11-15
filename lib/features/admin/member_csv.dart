/// Parses a member list pasted or loaded as CSV text.
///
/// Accepted: one member per line; `email` or `email,name`. Separators can be
/// comma, semicolon or tab. A header line (first cell "email") is skipped.
/// Quotes around cells are removed. Blank lines are ignored.
class MemberRow {
  const MemberRow({required this.email, required this.displayName});
  final String email;
  final String displayName;

  Map<String, dynamic> toJson() => {'email': email, 'display_name': displayName};
}

class CsvIssue {
  const CsvIssue(this.line, this.text, this.reason);
  final int line;
  final String text;
  final String reason;
}

class MemberCsvResult {
  const MemberCsvResult({required this.rows, required this.issues, required this.duplicates});
  final List<MemberRow> rows;
  final List<CsvIssue> issues;
  final int duplicates;
}

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String _clean(String s) {
  var t = s.trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    t = t.substring(1, t.length - 1).replaceAll('""', '"').trim();
  }
  return t;
}

/// "priya.k@example.com" -> "Priya K" (used when the CSV has no name).
String nameFromEmail(String email) {
  final local = email.split('@').first;
  final words = local
      .split(RegExp(r'[._\-+]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1));
  final name = words.join(' ');
  return name.length > 40 ? name.substring(0, 40) : name;
}

MemberCsvResult parseMemberCsv(String input) {
  final rows = <MemberRow>[];
  final issues = <CsvIssue>[];
  final seen = <String>{};
  var duplicates = 0;

  final lines = input.replaceAll('﻿', '').split(RegExp(r'\r\n|\r|\n'));
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    if (raw.trim().isEmpty) continue;
    final cells = raw.split(RegExp(r'[,;\t]')).map(_clean).toList();
    final email = cells.first.toLowerCase();

    if (i == 0 && (email == 'email' || email == 'e-mail' || email == 'email address')) {
      continue; // header
    }
    if (!_emailRe.hasMatch(email) || email.length > 254) {
      issues.add(CsvIssue(i + 1, raw.trim(), 'not a valid email'));
      continue;
    }
    if (!seen.add(email)) {
      duplicates++;
      continue;
    }
    var name = cells.length > 1 ? cells[1] : '';
    if (name.isEmpty) name = nameFromEmail(email);
    if (name.length > 40) name = name.substring(0, 40);
    rows.add(MemberRow(email: email, displayName: name));
  }
  return MemberCsvResult(rows: rows, issues: issues, duplicates: duplicates);
}

/// Credentials sheet for the admin to hand out. Cells are quoted and any
/// leading = + - @ is neutralised so spreadsheets never run it as a formula.
String credentialsCsv(Iterable<({String email, String password})> created) {
  String cell(String v) {
    final safe = RegExp(r'^[=+\-@]').hasMatch(v) ? "'$v" : v;
    return '"${safe.replaceAll('"', '""')}"';
  }

  final b = StringBuffer('email,temporary_password\n');
  for (final c in created) {
    b.writeln('${cell(c.email)},${cell(c.password)}');
  }
  return b.toString();
}
