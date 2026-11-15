import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/time/local_day.dart';
import 'step_day.dart';

/// Offline outbox of day totals waiting to reach the server.
///
/// One entry per (day, source): the newest Health reading, or the largest
/// sensor total, so a long offline period never grows unbounded and replays
/// are harmless.
/// Stored per profile so switching profiles on a shared phone never mixes
/// data.
class StepQueue {
  StepQueue(this._prefs, this.profileId);

  final SharedPreferences _prefs;
  final String profileId;

  String get _key => 'step_queue_$profileId';

  Map<String, StepDay> _load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return {};
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return {for (final j in list) StepDay.fromJson(j).key: StepDay.fromJson(j)};
    } catch (_) {
      return {}; // corrupt: drop it; fresh readings rebuild today's totals
    }
  }

  Future<void> _save(Map<String, StepDay> m) =>
      _prefs.setString(_key, jsonEncode([for (final d in m.values) d.toJson()]));

  /// Adds or raises an entry. Entries older than 31 days are dropped (the
  /// server would reject them anyway).
  Future<void> put(StepDay day, {DateTime? now}) async {
    final m = _load();
    final existing = m[day.key];
    m[day.key] = existing == null ? day : existing.merge(day);
    final cutoff = dateKey(daysAgo(now ?? DateTime.now(), 31));
    m.removeWhere((_, d) => d.localDate.compareTo(cutoff) < 0);
    await _save(m);
  }

  List<StepDay> pending() {
    final list = _load().values.toList()
      ..sort((a, b) => a.localDate.compareTo(b.localDate));
    return list;
  }

  int get pendingCount => _load().length;

  /// Removes entries the server has handled (accepted or definitively
  /// rejected). Anything not listed stays for the next attempt.
  Future<void> remove(Iterable<String> keys) async {
    final m = _load();
    for (final k in keys) {
      m.remove(k);
    }
    await _save(m);
  }

  Future<void> clear() => _prefs.remove(_key);
}
