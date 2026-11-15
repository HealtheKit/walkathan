import '../../core/time/local_day.dart';

enum EventPhase { upcoming, active, ended }

/// A walkathon event the signed-in account is on.
class MemberEvent {
  const MemberEvent({
    required this.id,
    required this.name,
    required this.startsOn,
    required this.endsOn,
    this.description,
  });

  final String id;
  final String name;
  final String? description;
  final DateTime startsOn;
  final DateTime endsOn;

  factory MemberEvent.fromMap(Map<String, dynamic> m) => MemberEvent(
        id: m['id'] as String,
        name: m['name'] as String,
        description: m['description'] as String?,
        startsOn: DateTime.parse(m['starts_on'] as String),
        endsOn: DateTime.parse(m['ends_on'] as String),
      );

  int get totalDays => endsOn.difference(startsOn).inDays + 1;

  EventPhase phase(DateTime now) {
    final t = startOfDay(now);
    if (t.isBefore(startOfDay(startsOn))) return EventPhase.upcoming;
    if (t.isAfter(startOfDay(endsOn))) return EventPhase.ended;
    return EventPhase.active;
  }

  /// 1-based day number within the event (clamped).
  int dayNumber(DateTime now) =>
      (startOfDay(now).difference(startOfDay(startsOn)).inDays + 1).clamp(1, totalDays);

  int daysUntilStart(DateTime now) =>
      startOfDay(startsOn).difference(startOfDay(now)).inDays;

  int daysLeft(DateTime now) =>
      startOfDay(endsOn).difference(startOfDay(now)).inDays.clamp(0, totalDays);

  /// Share of the event's days that have passed, 0..1.
  double progress(DateTime now) => switch (phase(now)) {
        EventPhase.upcoming => 0,
        EventPhase.ended => 1,
        EventPhase.active => dayNumber(now) / totalDays,
      };
}

/// Active events first (soonest to end), then upcoming (soonest to start),
/// then ended (most recent first).
List<MemberEvent> sortEvents(Iterable<MemberEvent> events, DateTime now) {
  int group(MemberEvent e) => switch (e.phase(now)) {
        EventPhase.active => 0,
        EventPhase.upcoming => 1,
        EventPhase.ended => 2,
      };
  final list = events.toList();
  list.sort((a, b) {
    final g = group(a).compareTo(group(b));
    if (g != 0) return g;
    return switch (group(a)) {
      0 => a.endsOn.compareTo(b.endsOn),
      1 => a.startsOn.compareTo(b.startsOn),
      _ => b.endsOn.compareTo(a.endsOn),
    };
  });
  return list;
}

enum BoardPeriod {
  event('event', 'Event'),
  week('week', 'This week'),
  day('day', 'Today');

  const BoardPeriod(this.wire, this.label);
  final String wire;
  final String label;
}

/// What the board ranks by.
enum BoardMetric {
  steps('steps', 'Total steps'),
  avg('avg', 'Daily average'),
  distance('distance', 'Distance'),
  activeDays('active_days', 'Active days');

  const BoardMetric(this.wire, this.label);
  final String wire;
  final String label;
}

/// Overall, or the men's / women's board.
enum BoardCohort {
  all(null, 'Everyone'),
  men('male', 'Men'),
  women('female', 'Women');

  const BoardCohort(this.wire, this.label);
  final String? wire;
  final String label;
}

class BoardRow {
  const BoardRow({
    required this.rank,
    required this.profileId,
    required this.name,
    required this.steps,
    required this.mine,
    this.value,
    this.gap = 0,
    this.topPct,
    this.distanceM = 0,
    this.activeDays = 0,
    this.avg = 0,
  });
  final int rank;
  final String profileId;
  final String name;
  final int steps;
  final bool mine;

  /// The ranked value for the chosen metric (defaults to steps).
  final int? value;

  /// Gap to the next rank up, in the metric's unit (0 for the leader).
  final int gap;

  /// Percentile position: 10 = top 10%.
  final int? topPct;
  final int distanceM;
  final int activeDays;
  final int avg;

  int get rankedValue => value ?? steps;

  factory BoardRow.fromMap(Map<String, dynamic> m) => BoardRow(
        rank: (m['rank'] as num).toInt(),
        profileId: m['profile_id'] as String,
        name: (m['name'] as String?) ?? 'Walker',
        steps: (m['steps'] as num?)?.toInt() ?? 0,
        mine: m['mine'] == true,
        value: (m['value'] as num?)?.toInt(),
        gap: (m['gap'] as num?)?.toInt() ?? 0,
        topPct: (m['top_pct'] as num?)?.toInt(),
        distanceM: (m['distance_m'] as num?)?.toInt() ?? 0,
        activeDays: (m['active_days'] as num?)?.toInt() ?? 0,
        avg: (m['avg'] as num?)?.toInt() ?? 0,
      );
}

/// Formats a metric value for display.
String formatMetric(BoardMetric m, int v, String Function(int) fmt) => switch (m) {
      BoardMetric.distance => '${(v / 1000).toStringAsFixed(1)} km',
      BoardMetric.activeDays => '$v ${v == 1 ? 'day' : 'days'}',
      _ => '${fmt(v)} steps',
    };

class EventBoard {
  const EventBoard({
    required this.walkers,
    required this.activeWalkers,
    required this.totalSteps,
    required this.rows,
    required this.mine,
    this.averageValue = 0,
    this.totalDistanceM = 0,
    this.status = 'published',
    this.showGenderBoards = true,
  });

  final int averageValue;
  final int totalDistanceM;

  /// published | paused | cancelled | draft
  final String status;
  final bool showGenderBoards;

  final int walkers;
  final int activeWalkers;
  final int totalSteps;

  /// Top of the board, in rank order.
  final List<BoardRow> rows;

  /// Every profile of the signed-in household, wherever it ranks.
  final List<BoardRow> mine;

  factory EventBoard.fromMap(Map<String, dynamic> m) {
    List<BoardRow> list(String key) => [
          for (final r in (m[key] as List? ?? const []))
            BoardRow.fromMap(Map<String, dynamic>.from(r as Map)),
        ];
    return EventBoard(
      walkers: (m['walkers'] as num?)?.toInt() ?? 0,
      activeWalkers: (m['active_walkers'] as num?)?.toInt() ?? 0,
      totalSteps: (m['total_steps'] as num?)?.toInt() ?? 0,
      rows: list('rows'),
      mine: list('mine'),
      averageValue: (m['average_value'] as num?)?.toInt() ?? 0,
      totalDistanceM: (m['total_distance_m'] as num?)?.toInt() ?? 0,
      status: ((m['event'] as Map?)?['status'] as String?) ?? 'published',
      showGenderBoards: ((m['event'] as Map?)?['show_gender_boards']) != false,
    );
  }

  /// My profiles that are not already visible in [rows].
  List<BoardRow> get mineOutsideTop {
    final shown = {for (final r in rows) r.profileId};
    return [for (final r in mine) if (!shown.contains(r.profileId)) r];
  }

  bool get nobodyHasWalked => activeWalkers == 0;
}
