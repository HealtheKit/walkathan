import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/core/time/local_day.dart';

void main() {
  test('dateKey pads month/day', () {
    expect(dateKey(DateTime(2026, 3, 5)), '2026-03-05');
    expect(dateKey(DateTime(2026, 12, 31, 23, 59)), '2026-12-31');
  });

  test('daysAgo crosses month and year boundaries', () {
    expect(dateKey(daysAgo(DateTime(2026, 3, 1, 15), 1)), '2026-02-28');
    expect(dateKey(daysAgo(DateTime(2026, 1, 1), 1)), '2025-12-31');
    expect(dateKey(daysAgo(DateTime(2024, 3, 1), 1)), '2024-02-29'); // leap year
  });

  test('weekStart is Monday', () {
    // 2026-11-13 is a Friday.
    expect(dateKey(weekStart(DateTime(2026, 11, 13))), '2026-11-09');
    expect(dateKey(weekStart(DateTime(2026, 11, 9))), '2026-11-09'); // Monday itself
    expect(dateKey(weekStart(DateTime(2026, 11, 15))), '2026-11-09'); // Sunday
  });

  test('startOfDay drops the time', () {
    expect(startOfDay(DateTime(2026, 5, 6, 13, 45, 12)), DateTime(2026, 5, 6));
  });
}
