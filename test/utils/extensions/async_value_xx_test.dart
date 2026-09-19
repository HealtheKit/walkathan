import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/utils/extensions/async_value_xx.dart';

void main() {
  group('AsyncValueXX.toStr', () {
    test('AsyncData includes the value', () {
      const value = AsyncValue<int>.data(42);
      expect(value.toStr, 'AsyncData<int>(value: 42)');
    });

    test('AsyncLoading has no value or error content', () {
      const value = AsyncValue<int>.loading();
      expect(value.toStr, 'AsyncLoading<int>()');
    });

    test('AsyncError includes the error', () {
      final value = AsyncValue<int>.error('boom', StackTrace.empty);
      expect(value.toStr, 'AsyncError<int>(error: boom)');
    });
  });

  group('AsyncValueXX.props', () {
    test('AsyncData reports hasValue true and hasError false', () {
      const value = AsyncValue<int>.data(1);
      expect(
        value.props,
        'isLoading: false, isRefreshing: false, isReloading: false\n'
        'hasValue: true, hasError: false',
      );
    });

    test('AsyncLoading reports isLoading true and hasValue false', () {
      const value = AsyncValue<int>.loading();
      expect(
        value.props,
        'isLoading: true, isRefreshing: false, isReloading: false\n'
        'hasValue: false, hasError: false',
      );
    });

    test('AsyncError reports hasError true and hasValue false', () {
      final value = AsyncValue<int>.error('boom', StackTrace.empty);
      expect(
        value.props,
        'isLoading: false, isRefreshing: false, isReloading: false\n'
        'hasValue: false, hasError: true',
      );
    });
  });
}
