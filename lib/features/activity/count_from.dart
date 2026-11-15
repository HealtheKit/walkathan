import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// "Count from" = the moment an organizer set this profile's counts to zero.
/// The phone then counts that day's steps only from this moment, so the walker
/// starts fresh and the old total can never come back on a later sync.
///
/// The server keeps the value (profiles.count_from); it is cached here so the
/// step sources, and the background sync that has no profile loaded, can use it.
String _key(String profileId) => 'count_from_$profileId';

Future<void> saveCountFrom(SharedPreferences prefs, String profileId, DateTime? at) async {
  if (at == null) {
    await prefs.remove(_key(profileId));
  } else {
    await prefs.setString(_key(profileId), at.toUtc().toIso8601String());
  }
}

/// Local time of the reset, or null when there is none.
Future<DateTime?> loadCountFrom(String profileId, [SharedPreferences? prefs]) async {
  final p = prefs ?? await SharedPreferences.getInstance();
  try {
    await p.reload(); // the background isolate must see what the app wrote
  } catch (_) {}
  return DateTime.tryParse(p.getString(_key(profileId)) ?? '')?.toLocal();
}

/// Where counting starts inside the day window [start]..[end]: the reset
/// moment when it falls inside the window, otherwise null (count the whole
/// day as usual). Days that ended before the reset are history and are left
/// alone; days after it are simply counted in full.
DateTime? cutInside(DateTime start, DateTime end, DateTime? countFrom) {
  if (countFrom == null) return null;
  if (!countFrom.isAfter(start) || !countFrom.isBefore(end)) return null;
  return countFrom;
}

/// The phone sensor only gives running totals, so a reset is applied by
/// remembering what each hour held when the phone first learned of it and
/// subtracting that from then on.
class SensorCut {
  SensorCut({required this.countFrom, required this.date, required this.baseHours});

  /// The reset this cut belongs to.
  final DateTime countFrom;

  /// Local day key ('YYYY-MM-DD') of the reset.
  final String date;

  /// Steps to subtract from each of the 24 hours of [date].
  final List<int> baseHours;

  /// Everything up to and including the reset hour is "before": it is
  /// snapshotted and never counted. Later hours start at zero.
  factory SensorCut.snapshot(DateTime countFrom, String date, List<int>? currentHours) {
    final cur = currentHours ?? List<int>.filled(24, 0);
    return SensorCut(
      countFrom: countFrom,
      date: date,
      baseHours: [for (var h = 0; h < 24; h++) h <= countFrom.hour ? cur[h] : 0],
    );
  }

  /// The day's hours with the pre-reset part removed (never negative).
  List<int> apply(List<int>? currentHours) {
    final cur = currentHours ?? List<int>.filled(24, 0);
    return [for (var h = 0; h < 24; h++) cur[h] > baseHours[h] ? cur[h] - baseHours[h] : 0];
  }

  String encode() => jsonEncode({
        'cf': countFrom.toUtc().toIso8601String(),
        'date': date,
        'base': baseHours,
      });

  static SensorCut? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final cf = DateTime.parse(j['cf'] as String).toLocal();
      final base = [for (final v in (j['base'] as List)) (v as num).toInt()];
      if (base.length != 24) return null;
      return SensorCut(countFrom: cf, date: j['date'] as String, baseHours: base);
    } catch (_) {
      return null;
    }
  }
}
