import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../repositories/auth_repository_provider.dart';

class SigninNotifier extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData<void>(null);

  Future<void> signin({
    required String email,
    required String password,
  }) async {
    state = const AsyncLoading<void>();

    state = await AsyncValue.guard<void>(
      () => ref
          .read(authRepositoryProvider)
          .signin(email: email, password: password),
    );
  }
}

final signinProvider =
    NotifierProvider<SigninNotifier, AsyncValue<void>>(SigninNotifier.new);
