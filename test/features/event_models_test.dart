import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/events/event_models.dart';

MemberEvent ev(String id, String from, String to) => MemberEvent(
    id: id, name: id, startsOn: DateTime.parse(from), endsOn: DateTime.parse(to));

void main() {
  final now = DateTime(2026, 11, 14, 10);

  test('phase, day number, days left and progress', () {
    final e = ev('a', '2026-11-10', '2026-11-19'); // 10 days
    expect(e.totalDays, 10);
    expect(e.phase(now), EventPhase.active);
    expect(e.dayNumber(now), 5);
    expect(e.daysLeft(now), 5);
    expect(e.progress(now), 0.5);

    expect(ev('b', '2026-11-20', '2026-11-25').phase(now), EventPhase.upcoming);
    expect(ev('b', '2026-11-20', '2026-11-25').daysUntilStart(now), 6);
    expect(ev('b', '2026-11-20', '2026-11-25').progress(now), 0);
    expect(ev('c', '2026-10-01', '2026-10-31').phase(now), EventPhase.ended);
    expect(ev('c', '2026-10-01', '2026-10-31').progress(now), 1);
  });

  test('first and last day are inside the event', () {
    final e = ev('a', '2026-11-14', '2026-11-14');
    expect(e.phase(now), EventPhase.active);
    expect(e.totalDays, 1);
    expect(e.daysLeft(now), 0);
    expect(e.phase(DateTime(2026, 11, 14, 23, 59)), EventPhase.active);
    expect(e.phase(DateTime(2026, 11, 15, 0, 1)), EventPhase.ended);
  });

  test('sortEvents: active, then upcoming (soonest), then ended (latest)', () {
    final sorted = sortEvents([
      ev('old', '2026-01-01', '2026-01-31'),
      ev('later', '2027-03-01', '2027-03-31'),
      ev('now', '2026-11-01', '2026-11-30'),
      ev('recent', '2026-10-01', '2026-10-31'),
      ev('soon', '2026-12-01', '2026-12-31'),
    ], now);
    expect(sorted.map((e) => e.id), ['now', 'soon', 'later', 'recent', 'old']);
  });

  test('EventBoard parses and separates my rows outside the top', () {
    final b = EventBoard.fromMap({
      'walkers': 4, 'active_walkers': 3, 'total_steps': 25000,
      'rows': [
        {'rank': 1, 'profile_id': 'p1', 'name': 'Bala', 'steps': 12000, 'mine': false},
        {'rank': 2, 'profile_id': 'p2', 'name': 'Asha', 'steps': 10000, 'mine': true},
      ],
      'mine': [
        {'rank': 2, 'profile_id': 'p2', 'name': 'Asha', 'steps': 10000, 'mine': true},
        {'rank': 3, 'profile_id': 'p3', 'name': 'Asha Jr', 'steps': 3000, 'mine': true},
      ],
    });
    expect(b.rows.length, 2);
    expect(b.mineOutsideTop.single.name, 'Asha Jr');
    expect(b.nobodyHasWalked, isFalse);
    expect(EventBoard.fromMap(const {}).nobodyHasWalked, isTrue);
  });
}
