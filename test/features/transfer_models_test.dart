import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/transfer/transfer_models.dart';

void main() {
  deviceModelTests();
  test('ProfileTransfer parses a pending request', () {
    final t = ProfileTransfer.fromMap({
      'id': 'a',
      'source_profile_id': 's',
      'source_name': 'Old',
      'target_name': 'New',
      'reason': 'Phone broke',
      'status': 'pending',
      'requested_at': '2026-11-01T10:00:00Z',
    });
    expect(t.isPending, isTrue);
    expect(t.sourceProfileId, 's');
    expect(t.status.label, 'Waiting for approval');
  });

  test('unknown status falls back to pending, never approved', () {
    expect(TransferStatus.parse('weird'), TransferStatus.pending);
    expect(TransferStatus.parse(null), TransferStatus.pending);
  });

  test('TransferReview parses totals and own_request', () {
    final r = TransferReview.fromMap({
      'id': 'a',
      'email': 'a@b.c',
      'status': 'approved',
      'requested_at': '2026-11-01T10:00:00Z',
      'source_steps': 123456,
      'source_days': 20,
      'target_steps': 10,
      'target_days': 1,
      'own_request': true,
    });
    expect(r.sourceSteps, 123456);
    expect(r.ownRequest, isTrue);
    expect(r.isPending, isFalse);
  });
}

void deviceModelTests() {
  test('unknown device status is never treated as approved', () {
    expect(DeviceStatus.parse('approved'), DeviceStatus.approved);
    expect(DeviceStatus.parse('weird'), DeviceStatus.pending);
    expect(DeviceStatus.parse(null), DeviceStatus.pending);
  });

  test('DeviceRequest parses', () {
    final d = DeviceRequest.fromMap({
      'account_id': 'a',
      'device_id': 'phone-0001',
      'email': 'm@x.y',
      'label': 'iPhone',
      'device_tail': '0001',
      'status': 'pending',
      'requested_at': '2026-11-01T10:00:00Z',
      'other_phones': 2,
      'own_request': false,
    });
    expect(d.isPending, isTrue);
    expect(d.otherPhones, 2);
    expect(d.label, 'iPhone');
  });
}
