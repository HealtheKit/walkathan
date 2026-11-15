import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants/firebase_constants.dart';
import '../../core/time/local_day.dart';
import '../../repositories/handle_exception.dart';
import 'event_models.dart';
import 'event_scoring.dart';
import '../../providers/profile_providers.dart';

class EventRepository {
  /// Events this account is on (row-level security does the filtering).
  Future<List<MemberEvent>> myEvents() async {
    try {
      final rows = await supabaseClient
          .from('events')
          .select('id, name, description, starts_on, ends_on');
      return sortEvents(rows.map(MemberEvent.fromMap), DateTime.now());
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<EventBoard> board(String eventId, BoardPeriod period,
      {BoardMetric metric = BoardMetric.steps, BoardCohort cohort = BoardCohort.all}) async {
    try {
      final res = await supabaseClient.rpc('event_board', params: {
        'p_event_id': eventId,
        'p_period': period.wire,
        'p_local_date': dateKey(DateTime.now()),
        'p_limit': 100,
        'p_metric': metric.wire,
        'p_sex': cohort.wire,
      });
      return EventBoard.fromMap(Map<String, dynamic>.from(res as Map));
    } catch (e) {
      throw handleException(e);
    }
  }
}

class MyEventStats {
  const MyEventStats({required this.config, required this.days, this.reward, this.announcements = const []});
  final EventConfig config;
  final List<EventDayRecord> days;
  final ({String award, String status})? reward;
  final List<({String title, String body, DateTime at})> announcements;

  factory MyEventStats.fromMap(Map m) {
    final e = m['event'] as Map;
    final r = m['reward'] as Map?;
    return MyEventStats(
      config: EventConfig(
        startsOn: DateTime.parse(e['starts_on'] as String),
        endsOn: DateTime.parse(e['ends_on'] as String),
        dailyTarget: (e['daily_target'] as num?)?.toInt() ?? 8000,
        rewardMinSteps: (e['reward_min_steps'] as num?)?.toInt(),
        rewardMinActivePct: (e['reward_min_active_pct'] as num?)?.toInt(),
      ),
      days: [for (final d in (m['days'] as List? ?? const [])) EventDayRecord.fromMap(d as Map)],
      reward: r == null ? null : (award: r['award'] as String, status: r['status'] as String),
      announcements: [
        for (final a in (m['announcements'] as List? ?? const []))
          (
            title: (a as Map)['title'] as String,
            body: a['body'] as String,
            at: DateTime.parse(a['at'] as String),
          ),
      ],
    );
  }
}

extension MyEventStatsCall on EventRepository {
  Future<MyEventStats> myStats(String profileId, String eventId) async {
    try {
      final res = await supabaseClient.rpc('my_event_stats', params: {
        'p_me': profileId,
        'p_event': eventId,
        'p_local_date': dateKey(DateTime.now()),
      });
      return MyEventStats.fromMap(res as Map);
    } catch (e) {
      throw handleException(e);
    }
  }
}

final eventRepositoryProvider =
    Provider<EventRepository>((ref) => EventRepository());

final myEventsProvider = FutureProvider.autoDispose<List<MemberEvent>>(
  (ref) => ref.watch(eventRepositoryProvider).myEvents(),
);

/// The event the user picked; null = the default (first in sort order).
class SelectedEventId extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String id) => state = id;
}

final selectedEventIdProvider =
    NotifierProvider<SelectedEventId, String?>(SelectedEventId.new);

/// The event shown on the dashboard.
final currentEventProvider = FutureProvider.autoDispose<MemberEvent?>((ref) async {
  final events = await ref.watch(myEventsProvider.future);
  if (events.isEmpty) return null;
  final picked = ref.watch(selectedEventIdProvider);
  return events.firstWhere((e) => e.id == picked, orElse: () => events.first);
});

typedef BoardKey = ({String eventId, BoardPeriod period, BoardMetric metric, BoardCohort cohort});

/// Shorthand for the default board (overall, by steps).
BoardKey boardKey(String eventId, BoardPeriod period,
        {BoardMetric metric = BoardMetric.steps, BoardCohort cohort = BoardCohort.all}) =>
    (eventId: eventId, period: period, metric: metric, cohort: cohort);

final eventBoardProvider =
    FutureProvider.autoDispose.family<EventBoard, BoardKey>(
  (ref, key) => ref
      .watch(eventRepositoryProvider)
      .board(key.eventId, key.period, metric: key.metric, cohort: key.cohort),
);

/// The active profile's own data for an event.
final myEventStatsProvider =
    FutureProvider.autoDispose.family<MyEventStats?, String>((ref, eventId) async {
  final profile = await ref.watch(activeProfileProvider.future);
  if (profile == null) return null;
  return ref.watch(eventRepositoryProvider).myStats(profile.id, eventId);
});
