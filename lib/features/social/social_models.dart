// Models for friends and groups. Parsed from server JSON; no I/O here.

class PersonRef {
  const PersonRef({required this.profileId, required this.name});
  final String profileId;
  final String name;

  factory PersonRef.fromMap(Map m) => PersonRef(
      profileId: m['profile_id'] as String, name: (m['name'] as String?) ?? 'Walker');
}

class Friend extends PersonRef {
  const Friend({
    required super.profileId,
    required super.name,
    required this.hidden,
    required this.sharing,
    this.todaySteps,
  });

  /// I have hidden them from my lists and boards.
  final bool hidden;

  /// They share their steps with friends.
  final bool sharing;

  /// Null when they are not sharing.
  final int? todaySteps;

  factory Friend.fromMap(Map m) => Friend(
        profileId: m['profile_id'] as String,
        name: (m['name'] as String?) ?? 'Walker',
        hidden: m['hidden'] == true,
        sharing: m['sharing'] == true,
        todaySteps: (m['today_steps'] as num?)?.toInt(),
      );
}

class FriendsOverview {
  const FriendsOverview({
    required this.code,
    required this.sharing,
    required this.friends,
    required this.incoming,
    required this.outgoing,
    required this.blocked,
  });

  final String code;

  /// Whether MY steps are shared with my friends.
  final bool sharing;
  final List<Friend> friends;
  final List<PersonRef> incoming;
  final List<PersonRef> outgoing;
  final List<PersonRef> blocked;

  factory FriendsOverview.fromMap(Map m) {
    List<PersonRef> refs(String k) =>
        [for (final x in (m[k] as List? ?? const [])) PersonRef.fromMap(x as Map)];
    return FriendsOverview(
      code: (m['code'] as String?) ?? '',
      sharing: m['sharing'] != false,
      friends: [for (final x in (m['friends'] as List? ?? const [])) Friend.fromMap(x as Map)],
      incoming: refs('incoming'),
      outgoing: refs('outgoing'),
      blocked: refs('blocked'),
    );
  }
}

/// A ranked row. [steps] is null when Mystery Mode is hiding the count.
class RankRow {
  const RankRow({
    required this.rank,
    required this.profileId,
    required this.name,
    required this.mine,
    this.steps,
  });
  final int rank;
  final String profileId;
  final String name;
  final bool mine;
  final int? steps;

  factory RankRow.fromMap(Map m) => RankRow(
        rank: (m['rank'] as num).toInt(),
        profileId: m['profile_id'] as String,
        name: (m['name'] as String?) ?? 'Walker',
        mine: m['mine'] == true,
        steps: (m['steps'] as num?)?.toInt(),
      );
}

List<RankRow> parseRankRows(Object? list) =>
    [for (final x in (list as List? ?? const [])) RankRow.fromMap(x as Map)];

enum SocialPeriod {
  day('day', 'Today'),
  week('week', 'This week'),
  month('month', 'This month'),
  challenge('challenge', 'Challenge');

  const SocialPeriod(this.wire, this.label);
  final String wire;
  final String label;
}

enum GroupRole {
  owner,
  admin,
  member;

  static GroupRole parse(String? v) =>
      GroupRole.values.firstWhere((r) => r.name == v, orElse: () => GroupRole.member);

  bool get isAdmin => this != GroupRole.member;
  String get label => switch (this) {
        GroupRole.owner => 'Owner',
        GroupRole.admin => 'Admin',
        GroupRole.member => 'Member',
      };
}

class GroupInfo {
  const GroupInfo({
    required this.id,
    required this.name,
    required this.role,
    required this.memberCount,
    required this.mysteryMode,
    required this.chatEnabled,
    required this.tauntsEnabled,
    this.challengeStart,
    this.challengeEnd,
  });

  final String id;
  final String name;
  final GroupRole role;
  final int memberCount;
  final bool mysteryMode;
  final bool chatEnabled;
  final bool tauntsEnabled;
  final DateTime? challengeStart;
  final DateTime? challengeEnd;

  bool get hasChallenge => challengeStart != null && challengeEnd != null;

  /// From `my_groups` (key `role`) or the `group` object of a board
  /// (key `my_role`).
  factory GroupInfo.fromMap(Map m) => GroupInfo(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        role: GroupRole.parse((m['role'] ?? m['my_role']) as String?),
        memberCount: (m['member_count'] as num?)?.toInt() ?? 0,
        mysteryMode: m['mystery_mode'] == true,
        chatEnabled: m['chat_enabled'] != false,
        tauntsEnabled: m['taunts_enabled'] != false,
        challengeStart: DateTime.tryParse((m['challenge_start'] as String?) ?? ''),
        challengeEnd: DateTime.tryParse((m['challenge_end'] as String?) ?? ''),
      );
}

class GroupBoard {
  const GroupBoard({
    required this.group,
    required this.rows,
    required this.mine,
    required this.stepsHidden,
    required this.excludesToday,
  });

  final GroupInfo group;
  final List<RankRow> rows;
  final List<RankRow> mine;

  /// Mystery Mode is hiding today's counts (ranks only).
  final bool stepsHidden;

  /// Mystery Mode: this longer period stops at yesterday.
  final bool excludesToday;

  factory GroupBoard.fromMap(Map m) => GroupBoard(
        group: GroupInfo.fromMap(m['group'] as Map),
        rows: parseRankRows(m['rows']),
        mine: parseRankRows(m['mine']),
        stepsHidden: m['steps_hidden'] == true,
        excludesToday: m['excludes_today'] == true,
      );

  List<RankRow> get mineOutsideTop {
    final shown = {for (final r in rows) r.profileId};
    return [for (final r in mine) if (!shown.contains(r.profileId)) r];
  }
}

class GroupMember extends PersonRef {
  const GroupMember({
    required super.profileId,
    required super.name,
    required this.role,
    required this.mine,
  });
  final GroupRole role;
  final bool mine;

  factory GroupMember.fromMap(Map m) => GroupMember(
        profileId: m['profile_id'] as String,
        name: (m['name'] as String?) ?? 'Walker',
        role: GroupRole.parse(m['role'] as String?),
        mine: m['mine'] == true,
      );
}

/// CSV for the admin report. Cells are quoted, and a leading = + - @ is
/// neutralised so a spreadsheet never runs a member's name as a formula.
String groupReportCsv(Map report) {
  String cell(Object? v) {
    final t = '${v ?? ''}';
    final safe = RegExp(r'^[=+\-@]').hasMatch(t) ? "'$t" : t;
    return '"${safe.replaceAll('"', '""')}"';
  }

  final b = StringBuffer()
    ..writeln('${cell('Group')},${cell(report['group'])}')
    ..writeln('${cell('From')},${cell(report['from'])}')
    ..writeln('${cell('To')},${cell(report['to'])}')
    ..writeln()
    ..writeln('rank,name,role,total_steps,active_days,best_day');
  final rows = (report['rows'] as List? ?? const []);
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i] as Map;
    b.writeln([
      i + 1,
      cell(r['name']),
      cell(r['role']),
      (r['total_steps'] as num?)?.toInt() ?? 0,
      (r['active_days'] as num?)?.toInt() ?? 0,
      (r['best_day'] as num?)?.toInt() ?? 0,
    ].join(','));
  }
  return b.toString();
}
