import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/pages/content/walk_home/pedometer_provider.dart';

void main() {
  group('PedometerState defaults', () {
    test('uses documented default values', () {
      final state = PedometerState();

      expect(state.steps, '0');
      expect(state.count, 0);
      expect(state.status, '?');
      expect(state.lastUpdate, isNull);
    });
  });

  group('PedometerState.copyWith', () {
    test('overrides only the provided fields', () {
      final original = PedometerState(steps: '10', count: 10, status: 'walking');
      final updated = original.copyWith(count: 11);

      expect(updated.steps, '10');
      expect(updated.count, 11);
      expect(updated.status, 'walking');
      expect(updated.lastUpdate, original.lastUpdate);
    });

    test('keeps all original fields when called with no arguments', () {
      final now = DateTime(2024, 1, 1);
      final original = PedometerState(steps: '5', count: 5, status: 'stopped', lastUpdate: now);
      final copy = original.copyWith();

      expect(copy.steps, original.steps);
      expect(copy.count, original.count);
      expect(copy.status, original.status);
      expect(copy.lastUpdate, original.lastUpdate);
    });

    test('updates lastUpdate independently of other fields', () {
      final original = PedometerState();
      final now = DateTime(2024, 6, 15);
      final updated = original.copyWith(lastUpdate: now);

      expect(updated.lastUpdate, now);
      expect(updated.steps, original.steps);
      expect(updated.count, original.count);
      expect(updated.status, original.status);
    });

    test('updates all fields at once', () {
      final now = DateTime(2024, 1, 1);
      final updated = PedometerState().copyWith(
        steps: '100',
        count: 100,
        status: 'walking',
        lastUpdate: now,
      );

      expect(updated.steps, '100');
      expect(updated.count, 100);
      expect(updated.status, 'walking');
      expect(updated.lastUpdate, now);
    });
  });
}
