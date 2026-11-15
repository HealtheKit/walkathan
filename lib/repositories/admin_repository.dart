import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/firebase_constants.dart';
import '../features/admin/member_csv.dart';
import '../models/custom_error.dart';
import 'handle_exception.dart';

class Member {
  const Member({
    required this.accountId,
    required this.email,
    required this.createdAt,
    required this.lastSignInAt,
    required this.profileCount,
    required this.isDisabled,
  });

  final String accountId;
  final String email;
  final DateTime createdAt;
  final DateTime? lastSignInAt;
  final int profileCount;
  final bool isDisabled;

  factory Member.fromMap(Map<String, dynamic> m) => Member(
        accountId: m['account_id'] as String,
        email: m['email'] as String? ?? '',
        createdAt: DateTime.parse(m['created_at'] as String),
        lastSignInAt: m['last_sign_in_at'] == null
            ? null
            : DateTime.parse(m['last_sign_in_at'] as String),
        profileCount: (m['profile_count'] as num?)?.toInt() ?? 0,
        isDisabled: m['is_disabled'] == true,
      );
}

class WalkEvent {
  const WalkEvent({
    required this.id,
    required this.name,
    required this.startsOn,
    required this.endsOn,
    required this.memberCount,
    this.description,
    this.status = 'published',
    this.dailyCap,
    this.dailyTarget = 8000,
    this.rewardMinSteps,
    this.rewardMinActivePct,
    this.showGenderBoards = true,
  });

  /// draft | published | paused | cancelled
  final String status;
  final int? dailyCap;
  final int dailyTarget;
  final int? rewardMinSteps;
  final int? rewardMinActivePct;
  final bool showGenderBoards;
  final String id;
  final String name;
  final String? description;
  final DateTime startsOn;
  final DateTime endsOn;
  final int memberCount;

  factory WalkEvent.fromMap(Map<String, dynamic> m) => WalkEvent(
        id: m['id'] as String,
        name: m['name'] as String,
        description: m['description'] as String?,
        startsOn: DateTime.parse(m['starts_on'] as String),
        endsOn: DateTime.parse(m['ends_on'] as String),
        memberCount: (m['member_count'] as num?)?.toInt() ?? 0,
        status: (m['status'] as String?) ?? 'published',
        dailyCap: (m['daily_cap'] as num?)?.toInt(),
        dailyTarget: (m['daily_target'] as num?)?.toInt() ?? 8000,
        rewardMinSteps: (m['reward_min_steps'] as num?)?.toInt(),
        rewardMinActivePct: (m['reward_min_active_pct'] as num?)?.toInt(),
        showGenderBoards: m['show_gender_boards'] != false,
      );
}

class RosterEntry {
  const RosterEntry({
    required this.accountId,
    required this.email,
    required this.profileCount,
    required this.hasSignedIn,
    this.status = 'active',
  });

  /// active | removed | blocked
  final String status;
  final String accountId;
  final String email;
  final int profileCount;
  final bool hasSignedIn;
}

/// One line of a bulk import result.
class ImportOutcome {
  const ImportOutcome({required this.email, required this.status, this.tempPassword});
  final String email;

  /// created | existing | invalid | error
  final String status;
  final String? tempPassword;
}

/// Super Admin operations. All authorization happens server-side in the
/// `admin-members` Edge Function; the client only calls it.
class AdminRepository {
  Future<bool> isSuperAdmin() async {
    try {
      final result = await supabaseClient.rpc('is_platform_admin');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    try {
      final res = await supabaseClient.functions
          .invoke('admin-members', body: body);
      final data = res.data;
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on FunctionException catch (e) {
      final details = e.details;
      final msg = details is Map ? details['error']?.toString() : null;
      throw CustomError(
        code: 'admin-${e.status}',
        message: _friendly(e.status, msg),
        plugin: 'edge_function',
      );
    } catch (e) {
      throw handleException(e);
    }
  }

  String _friendly(int status, String? msg) {
    if (status == 403) return 'Only a Super Admin can do this.';
    if (status == 409) return 'That email is already registered.';
    if (status == 400 && msg != null) return 'Invalid request: $msg';
    return 'Something went wrong. Please try again.';
  }

  Future<List<Member>> listMembers() async {
    final data = await _call({'action': 'list'});
    final list = (data['members'] as List?) ?? const [];
    return list
        .map((m) => Member.fromMap(Map<String, dynamic>.from(m as Map)))
        .toList();
  }

  /// Returns the temporary password. Shown once; never stored.
  Future<String> createMember({
    required String email,
    required String displayName,
  }) async {
    final data = await _call(
        {'action': 'create', 'email': email, 'display_name': displayName});
    return data['temp_password'] as String;
  }

  Future<String> resetPassword(String accountId) async {
    final data =
        await _call({'action': 'reset_password', 'account_id': accountId});
    return data['temp_password'] as String;
  }

  Future<void> setDisabled(String accountId, {required bool disabled}) =>
      _call({
        'action': disabled ? 'disable' : 'enable',
        'account_id': accountId,
      });

  Future<void> deleteMember(String accountId) =>
      _call({'action': 'delete', 'account_id': accountId});

  // ------------------------------------------------------------ events

  Future<T> _rpc<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw handleException(e);
    }
  }

  /// super | organizer | verifier | viewer | null
  Future<String?> staffRole() async {
    try {
      return await supabaseClient.rpc('staff_role') as String?;
    } catch (_) {
      return null;
    }
  }

  Future<List<WalkEvent>> listEvents() => _rpc(() async {
        final rows = await supabaseClient.rpc('admin_list_events') as List? ?? const [];
        return rows
            .map((r) => WalkEvent.fromMap(Map<String, dynamic>.from(r as Map)))
            .toList();
      });

  Future<void> createEvent({
    required String name,
    required DateTime startsOn,
    required DateTime endsOn,
    String? description,
  }) =>
      _rpc(() => supabaseClient.rpc('admin_create_event', params: {
            'p_name': name,
            'p_starts_on': _d(startsOn),
            'p_ends_on': _d(endsOn),
            'p_description': description,
          }));

  Future<void> deleteEvent(String eventId) => _rpc(() =>
      supabaseClient.rpc('admin_delete_event', params: {'p_event_id': eventId}));

  Future<List<RosterEntry>> eventRoster(String eventId) => _rpc(() async {
        final rows = await supabaseClient
            .rpc('admin_event_roster', params: {'p_event_id': eventId}) as List;
        return [
          for (final r in rows)
            RosterEntry(
              accountId: r['account_id'] as String,
              email: r['email'] as String? ?? '',
              profileCount: (r['profile_count'] as num?)?.toInt() ?? 0,
              hasSignedIn: r['has_signed_in'] == true,
              status: (r['status'] as String?) ?? 'active',
            ),
        ];
      });

  Future<void> removeFromEvent(String eventId, String accountId) =>
      _rpc(() => supabaseClient.rpc('admin_remove_event_account',
          params: {'p_event_id': eventId, 'p_account_id': accountId}));

  /// Imports up to 50 rows into an event (server limit per call).
  Future<List<ImportOutcome>> bulkImportChunk(
      String eventId, List<MemberRow> rows) async {
    final data = await _call({
      'action': 'bulk_import',
      'event_id': eventId,
      'rows': [for (final r in rows) r.toJson()],
    });
    return [
      for (final r in (data['results'] as List? ?? const []))
        ImportOutcome(
          email: r['email'] as String? ?? '',
          status: r['status'] as String? ?? 'error',
          tempPassword: r['temp_password'] as String?,
        ),
    ];
  }

  Future<void> updateEvent(String eventId,
          {String? name,
          DateTime? startsOn,
          DateTime? endsOn,
          String? status,
          int? dailyCap,
          bool clearCap = false,
          int? dailyTarget,
          int? rewardMinSteps,
          int? rewardMinActivePct,
          bool? showGenderBoards}) =>
      _rpc(() => supabaseClient.rpc('admin_update_event', params: {
            'p_event': eventId,
            'p_name': name,
            'p_starts_on': startsOn == null ? null : _d(startsOn),
            'p_ends_on': endsOn == null ? null : _d(endsOn),
            'p_status': status,
            'p_daily_cap': dailyCap,
            'p_clear_cap': clearCap,
            'p_daily_target': dailyTarget,
            'p_reward_min_steps': rewardMinSteps,
            'p_reward_min_active_pct': rewardMinActivePct,
            'p_show_gender_boards': showGenderBoards,
          }));

  Future<Map<String, dynamic>> eventOverview(String eventId) => _rpc(() async =>
      Map<String, dynamic>.from(await supabaseClient.rpc('admin_event_overview',
          params: {'p_event': eventId, 'p_local_date': _d(DateTime.now())}) as Map));

  Future<List<Map<String, dynamic>>> participantDays(String eventId, String profileId) =>
      _rpc(() async => [
            for (final r in (await supabaseClient.rpc('admin_participant_days',
                params: {'p_event': eventId, 'p_profile': profileId}) as List))
              Map<String, dynamic>.from(r as Map),
          ]);

  /// Sets event counts back to zero: for [profileId], or everyone on the
  /// event when null. Nothing is deleted; it can be undone. Returns how many
  /// profiles were reset.
  Future<int> resetCounts(String eventId, {String? profileId, required String note}) =>
      _rpc(() async => ((await supabaseClient.rpc('admin_reset_counts', params: {
            'p_event': eventId,
            'p_profile': profileId,
            'p_local_date': _d(DateTime.now()),
            'p_note': note,
          })) as num)
              .toInt());

  Future<int> undoReset(String eventId, {String? profileId}) =>
      _rpc(() async => ((await supabaseClient.rpc('admin_undo_reset',
              params: {'p_event': eventId, 'p_profile': profileId})) as num)
          .toInt());

  /// Independent recount of the whole pipeline for an event.
  Future<Map<String, dynamic>> validateCounts(String eventId, {bool repair = false}) =>
      _rpc(() async => Map<String, dynamic>.from(await supabaseClient.rpc(
          'admin_validate_counts',
          params: {'p_event': eventId, 'p_repair': repair}) as Map));

  /// action: exclude | cap | clear
  Future<void> correctDay(String profileId, DateTime date, String action,
          {int? cap, String? reason}) =>
      _rpc(() => supabaseClient.rpc('admin_correct_day', params: {
            'p_profile': profileId,
            'p_date': _d(date),
            'p_action': action,
            'p_cap': cap,
            'p_reason': reason,
          }));

  Future<void> requestResync(String profileId) =>
      _rpc(() => supabaseClient.rpc('admin_request_resync', params: {'p_profile': profileId}));

  Future<void> setParticipantStatus(String eventId, String accountId, String status) =>
      _rpc(() => supabaseClient.rpc('admin_set_participant_status',
          params: {'p_event': eventId, 'p_account': accountId, 'p_status': status}));

  Future<void> moveParticipant(String fromEvent, String toEvent, String accountId) =>
      _rpc(() => supabaseClient.rpc('admin_move_participant',
          params: {'p_from': fromEvent, 'p_to': toEvent, 'p_account': accountId}));

  Future<void> setProfileSex(String profileId, String? sex) =>
      _rpc(() => supabaseClient.rpc('admin_set_profile_sex', params: {'p_profile': profileId, 'p_sex': sex}));

  Future<void> postAnnouncement(String eventId, String audience, String title, String body) =>
      _rpc(() => supabaseClient.rpc('admin_post_announcement',
          params: {'p_event': eventId, 'p_audience': audience, 'p_title': title, 'p_body': body}));

  /// award null removes it. status: selected | awarded | delivered
  Future<void> setReward(String eventId, String profileId, String? award, String status) =>
      _rpc(() => supabaseClient.rpc('admin_set_reward', params: {
            'p_event': eventId,
            'p_profile': profileId,
            'p_award': award,
            'p_status': status,
          }));

  Future<List<({String email, String role})>> listStaff() => _rpc(() async => [
        for (final r in (await supabaseClient.rpc('admin_list_staff') as List))
          (email: (r as Map)['email'] as String, role: r['role'] as String),
      ]);

  /// role null removes the role. Returns ok | not_found.
  Future<String> setStaff(String email, String? role) => _rpc(() async =>
      await supabaseClient.rpc('admin_set_staff', params: {'p_email': email, 'p_role': role})
          as String);

  static String _d(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Runs a large import in chunks of [chunkSize] so no single request is
/// slow, reporting progress. A failed chunk marks its rows as errors and the
/// import continues; re-importing the same list later is safe (existing
/// accounts are simply added to the event).
Future<List<ImportOutcome>> importInChunks({
  required List<MemberRow> rows,
  required Future<List<ImportOutcome>> Function(List<MemberRow> chunk) send,
  void Function(int done, int total)? onProgress,
  int chunkSize = 50,
}) async {
  final all = <ImportOutcome>[];
  for (var i = 0; i < rows.length; i += chunkSize) {
    final chunk =
        rows.sublist(i, i + chunkSize > rows.length ? rows.length : i + chunkSize);
    try {
      all.addAll(await send(chunk));
    } catch (_) {
      all.addAll([for (final r in chunk) ImportOutcome(email: r.email, status: 'error')]);
    }
    onProgress?.call(i + chunk.length, rows.length);
  }
  return all;
}
