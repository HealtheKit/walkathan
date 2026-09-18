import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../repositories/auth_repository_provider.dart';

class ResetPasswordNotifier extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData<void>(null);

  Future<void> resetPassword({required String email}) async {
    state = const AsyncLoading<void>();

    state = await AsyncValue.guard<void>(
      () => ref.read(authRepositoryProvider).sendPasswordResetEmail(email),
    );
  }
}

final resetPasswordProvider =
    NotifierProvider<ResetPasswordNotifier, AsyncValue<void>>(
        ResetPasswordNotifier.new);
