import '../constants/firebase_constants.dart';
import '../features/transfer/transfer_models.dart';
import 'handle_exception.dart';

/// Profile transfers (new phone) and per-event organizers. Every rule is
/// enforced by the server functions; this class only calls them.
class TransferRepository {
  Future<T> _rpc<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw handleException(e);
    }
  }

  List<Map<String, dynamic>> _rows(Object? data) => [
        for (final r in (data as List? ?? const []))
          Map<String, dynamic>.from(r as Map),
      ];

  // ------------------------------------------------------------ member

  Future<void> request({
    required String sourceProfileId,
    required String targetProfileId,
    required String deviceId,
    required String reason,
  }) =>
      _rpc(() => supabaseClient.rpc('request_profile_transfer', params: {
            'p_source': sourceProfileId,
            'p_target': targetProfileId,
            'p_device_id': deviceId,
            'p_reason': reason.trim(),
          }));

  Future<void> cancel(String id) => _rpc(
      () => supabaseClient.rpc('cancel_profile_transfer', params: {'p_id': id}));

  Future<List<ProfileTransfer>> mine() => _rpc(() async {
        final data = await supabaseClient.rpc('my_profile_transfers');
        return _rows(data).map(ProfileTransfer.fromMap).toList();
      });

  // ---------------------------------------------------------- reviewers

  Future<bool> isReviewer() async {
    try {
      return await supabaseClient.rpc('is_transfer_reviewer') == true;
    } catch (_) {
      return false;
    }
  }

  Future<int> pendingCount() async {
    try {
      return ((await supabaseClient.rpc('pending_approval_count')) as num)
          .toInt();
    } catch (_) {
      return 0;
    }
  }

  /// [status] null = every status (history).
  Future<List<TransferReview>> review({String? status = 'pending'}) =>
      _rpc(() async {
        final data = await supabaseClient
            .rpc('review_profile_transfers', params: {'p_status': status});
        return _rows(data).map(TransferReview.fromMap).toList();
      });

  /// Returns the server outcome: approved | rejected | already_* | profile_missing.
  Future<String> decide(String id,
          {required bool approve, String? note}) =>
      _rpc(() async {
        final r = await supabaseClient.rpc('decide_profile_transfer',
            params: {'p_id': id, 'p_approve': approve, 'p_note': note});
        return r as String;
      });

  // -------------------------------------------------------- new phones

  /// Tells the server this phone is being used and returns its status.
  Future<({DeviceStatus status, String? note})> registerDevice(
          String deviceId, String label, {bool retry = false}) =>
      _rpc(() async {
        final r = await supabaseClient.rpc('register_login_device', params: {
          'p_device_id': deviceId,
          'p_label': label,
          'p_retry': retry,
        }) as Map;
        return (
          status: DeviceStatus.parse(r['status'] as String?),
          note: r['note'] as String?,
        );
      });

  Future<List<DeviceRequest>> deviceRequests({String? status = 'pending'}) =>
      _rpc(() async {
        final data = await supabaseClient
            .rpc('review_device_requests', params: {'p_status': status});
        return _rows(data).map(DeviceRequest.fromMap).toList();
      });

  Future<String> decideDevice(DeviceRequest d,
          {required bool approve, String? note}) =>
      _rpc(() async {
        final r = await supabaseClient.rpc('decide_device', params: {
          'p_account': d.accountId,
          'p_device_id': d.deviceId,
          'p_approve': approve,
          'p_note': note,
        });
        return r as String;
      });

  // --------------------------------------------------- event organizers

  Future<List<EventOrganizer>> organizers(String eventId) => _rpc(() async {
        final data = await supabaseClient
            .rpc('list_event_organizers', params: {'p_event': eventId});
        return _rows(data).map(EventOrganizer.fromMap).toList();
      });

  /// Returns 'ok' or 'not_found' (no login with that email).
  Future<String> addOrganizer(String eventId, String email) => _rpc(() async {
        final r = await supabaseClient.rpc('add_event_organizer',
            params: {'p_event': eventId, 'p_email': email.trim()});
        return r as String;
      });

  Future<void> removeOrganizer(String eventId, String userId) =>
      _rpc(() => supabaseClient.rpc('remove_event_organizer',
          params: {'p_event': eventId, 'p_user': userId}));
}
