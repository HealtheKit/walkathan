import '../constants/firebase_constants.dart';
import '../features/activity/step_day.dart';
import '../features/activity/step_sync_service.dart';
import '../models/custom_error.dart';
import 'handle_exception.dart';

/// Step data access. The only WRITE path is the server function
/// `ingest_steps`; clients cannot write step tables directly.
class StepRepository implements StepUploader {
  @override
  Future<List<IngestResult>> ingest({
    required String profileId,
    required String deviceId,
    required List<StepDay> days,
  }) async {
    try {
      final res = await supabaseClient.rpc('ingest_steps', params: {
        'p_profile_id': profileId,
        'p_device_id': deviceId,
        'p_days': [for (final d in days) d.toJson()],
      });
      final list = (res as List).cast<Map<String, dynamic>>();
      return [
        for (final r in list)
          IngestResult(
            localDate: r['local_date'] as String,
            ok: r['status'] == 'ok',
            reason: r['reason'] as String?,
          ),
      ];
    } catch (e) {
      throw handleException(e);
    }
  }

  /// When an organizer last set this profile's counts to zero (null: never,
  /// or the reset was undone). Throws when offline.
  Future<DateTime?> fetchCountFrom(String profileId) async {
    final row = await supabaseClient
        .from('profiles')
        .select('count_from')
        .eq('id', profileId)
        .maybeSingle();
    return DateTime.tryParse((row?['count_from'] as String?) ?? '');
  }

  /// Resolved day totals for [from]..[to] inclusive (local dates).
  Future<List<StoredDay>> fetchDays(
      String profileId, String from, String to) async {
    try {
      final rows = await supabaseClient
          .from('step_days')
          .select('local_date, steps, distance_m, kcal, floors, source')
          .eq('profile_id', profileId)
          .gte('local_date', from)
          .lte('local_date', to)
          .order('local_date');
      return rows
          .map((r) => StoredDay(
                localDate: r['local_date'] as String,
                steps: (r['steps'] as num).toInt(),
                distanceM: (r['distance_m'] as num?)?.toInt(),
                kcal: (r['kcal'] as num?)?.toInt(),
                floors: (r['floors'] as num?)?.toInt(),
              ))
          .toList();
    } catch (e) {
      throw handleException(e);
    }
  }

  /// Asks the server which profile this phone belongs to, binding it to
  /// [profileId] when it is free.
  Future<DeviceClaim> claimDevice(String deviceId, String profileId) async {
    try {
      final r = await supabaseClient.rpc('claim_device',
          params: {'p_device_id': deviceId, 'p_profile_id': profileId}) as Map;
      return DeviceClaim(
        mine: r['mine'] == true,
        ownerProfileId: r['owner_profile_id'] as String?,
        ownerName: r['owner_name'] as String?,
        canMove: r['can_move'] == true,
      );
    } catch (e) {
      throw handleException(e);
    }
  }

  /// Moves this phone to [profileId] (allowed within an hour of binding, or
  /// after 7 idle days).
  Future<void> moveDevice(String deviceId, String profileId) async {
    try {
      await supabaseClient.rpc('move_device',
          params: {'p_device_id': deviceId, 'p_profile_id': profileId});
    } catch (e) {
      if (e.toString().contains('device locked')) {
        throw const CustomError(
            code: 'device-locked',
            message:
                'This phone already counts steps for another profile. It can '
                'be switched after it has not been used for 7 days.',
            plugin: 'supabase_db');
      }
      throw handleException(e);
    }
  }

  Future<Set<String>> fetchRestDays(
      String profileId, String from, String to) async {
    try {
      final rows = await supabaseClient
          .from('rest_days')
          .select('local_date')
          .eq('profile_id', profileId)
          .gte('local_date', from)
          .lte('local_date', to);
      return {for (final r in rows) r['local_date'] as String};
    } catch (e) {
      throw handleException(e);
    }
  }

  Future<void> addRestDay(String profileId, String localDate) async {
    try {
      await supabaseClient
          .from('rest_days')
          .insert({'profile_id': profileId, 'local_date': localDate});
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('rest day limit reached')) {
        throw const CustomError(
            code: 'rest-limit',
            message: 'You can take at most 2 rest days per week.',
            plugin: 'supabase_db');
      }
      if (msg.contains('rest day date not allowed')) {
        throw const CustomError(
            code: 'rest-date',
            message: 'Rest days can only be set for today or upcoming days.',
            plugin: 'supabase_db');
      }
      throw handleException(e);
    }
  }

  Future<void> removeRestDay(String profileId, String localDate) async {
    try {
      await supabaseClient
          .from('rest_days')
          .delete()
          .eq('profile_id', profileId)
          .eq('local_date', localDate);
    } catch (e) {
      throw handleException(e);
    }
  }
}

/// Who a phone belongs to.
class DeviceClaim {
  const DeviceClaim({
    required this.mine,
    this.ownerProfileId,
    this.ownerName,
    this.canMove = false,
  });
  final bool mine;

  /// Null when the phone belongs to a different household.
  final String? ownerProfileId;
  final String? ownerName;
  final bool canMove;
}

/// A day as stored on the server (after combining sources).
class StoredDay {
  const StoredDay({
    required this.localDate,
    required this.steps,
    this.distanceM,
    this.kcal,
    this.floors,
  });
  final String localDate;
  final int steps;
  final int? distanceM;
  final int? kcal;
  final int? floors;
}
