import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../repositories/auth_repository_provider.dart';

class ChangePasswordNotifier extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData<void>(null);

  Future<void> changePassword(String password) async {
    state = const AsyncLoading<void>();

    state = await AsyncValue.guard<void>(
      () => ref.read(authRepositoryProvider).changePassword(password),
    );
  }
}

final changePasswordProvider =
    NotifierProvider<ChangePasswordNotifier, AsyncValue<void>>(
        ChangePasswordNotifier.new);
