/// A request to move an OLD profile's data into the profile on a new phone.
/// Created by the member, decided by a Super Admin or an event organizer.
enum TransferStatus {
  pending,
  approved,
  rejected,
  cancelled;

  static TransferStatus parse(String? s) => TransferStatus.values
      .firstWhere((e) => e.name == s, orElse: () => TransferStatus.pending);

  String get label => switch (this) {
        TransferStatus.pending => 'Waiting for approval',
        TransferStatus.approved => 'Approved',
        TransferStatus.rejected => 'Rejected',
        TransferStatus.cancelled => 'Cancelled',
      };
}

DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// The member's own view of a request.
class ProfileTransfer {
  const ProfileTransfer({
    required this.id,
    required this.sourceName,
    required this.targetName,
    required this.reason,
    required this.status,
    required this.requestedAt,
    this.sourceProfileId,
    this.decidedAt,
    this.decisionNote,
  });

  final String id;
  final String? sourceProfileId;
  final String sourceName;
  final String targetName;
  final String reason;
  final TransferStatus status;
  final DateTime requestedAt;
  final DateTime? decidedAt;
  final String? decisionNote;

  bool get isPending => status == TransferStatus.pending;

  factory ProfileTransfer.fromMap(Map<String, dynamic> m) => ProfileTransfer(
        id: m['id'] as String,
        sourceProfileId: m['source_profile_id'] as String?,
        sourceName: (m['source_name'] as String?) ?? '',
        targetName: (m['target_name'] as String?) ?? '',
        reason: (m['reason'] as String?) ?? '',
        status: TransferStatus.parse(m['status'] as String?),
        requestedAt: _dt(m['requested_at']) ?? DateTime.now(),
        decidedAt: _dt(m['decided_at']),
        decisionNote: m['decision_note'] as String?,
      );
}

/// What an approver sees. Only totals, never daily detail.
class TransferReview {
  const TransferReview({
    required this.id,
    required this.email,
    required this.sourceName,
    required this.targetName,
    required this.reason,
    required this.status,
    required this.requestedAt,
    required this.sourceDays,
    required this.sourceSteps,
    required this.targetDays,
    required this.targetSteps,
    required this.ownRequest,
    this.decidedAt,
    this.decisionNote,
    this.sourceLastUpload,
  });

  final String id;
  final String email;
  final String sourceName;
  final String targetName;
  final String reason;
  final TransferStatus status;
  final DateTime requestedAt;
  final DateTime? decidedAt;
  final String? decisionNote;
  final int sourceDays;
  final int sourceSteps;
  final int targetDays;
  final int targetSteps;
  final DateTime? sourceLastUpload;

  /// The approver is the requester: only a Super Admin can approve it.
  final bool ownRequest;

  bool get isPending => status == TransferStatus.pending;

  factory TransferReview.fromMap(Map<String, dynamic> m) => TransferReview(
        id: m['id'] as String,
        email: (m['email'] as String?) ?? '',
        sourceName: (m['source_name'] as String?) ?? '',
        targetName: (m['target_name'] as String?) ?? '',
        reason: (m['reason'] as String?) ?? '',
        status: TransferStatus.parse(m['status'] as String?),
        requestedAt: _dt(m['requested_at']) ?? DateTime.now(),
        decidedAt: _dt(m['decided_at']),
        decisionNote: m['decision_note'] as String?,
        sourceDays: (m['source_days'] as num?)?.toInt() ?? 0,
        sourceSteps: (m['source_steps'] as num?)?.toInt() ?? 0,
        targetDays: (m['target_days'] as num?)?.toInt() ?? 0,
        targetSteps: (m['target_steps'] as num?)?.toInt() ?? 0,
        sourceLastUpload: _dt(m['source_last_upload']),
        ownRequest: m['own_request'] == true,
      );
}

/// An organizer of one event (an event can have several).
class EventOrganizer {
  const EventOrganizer({required this.userId, required this.email});
  final String userId;
  final String email;

  factory EventOrganizer.fromMap(Map<String, dynamic> m) => EventOrganizer(
        userId: m['user_id'] as String,
        email: (m['email'] as String?) ?? '',
      );
}

/// Result of asking the server about THIS phone.
enum DeviceStatus {
  approved,
  pending,
  rejected;

  static DeviceStatus parse(String? s) => DeviceStatus.values.firstWhere(
      (e) => e.name == s,
      orElse: () => DeviceStatus.pending); // unknown = not approved
}

/// A new phone waiting for (or past) approval, as an approver sees it.
class DeviceRequest {
  const DeviceRequest({
    required this.accountId,
    required this.deviceId,
    required this.email,
    required this.label,
    required this.deviceTail,
    required this.status,
    required this.requestedAt,
    required this.otherPhones,
    required this.ownRequest,
    this.lastOtherUse,
    this.decidedAt,
    this.decisionNote,
  });

  final String accountId;
  final String deviceId;
  final String email;
  final String label;
  final String deviceTail;
  final TransferStatus status; // pending | approved | rejected
  final DateTime requestedAt;
  final int otherPhones;
  final DateTime? lastOtherUse;
  final DateTime? decidedAt;
  final String? decisionNote;
  final bool ownRequest;

  bool get isPending => status == TransferStatus.pending;

  factory DeviceRequest.fromMap(Map<String, dynamic> m) => DeviceRequest(
        accountId: m['account_id'] as String,
        deviceId: m['device_id'] as String,
        email: (m['email'] as String?) ?? '',
        label: (m['label'] as String?) ?? 'Phone',
        deviceTail: (m['device_tail'] as String?) ?? '',
        status: TransferStatus.parse(m['status'] as String?),
        requestedAt: _dt(m['requested_at']) ?? DateTime.now(),
        otherPhones: (m['other_phones'] as num?)?.toInt() ?? 0,
        lastOtherUse: _dt(m['last_other_use']),
        decidedAt: _dt(m['decided_at']),
        decisionNote: m['decision_note'] as String?,
        ownRequest: m['own_request'] == true,
      );
}
