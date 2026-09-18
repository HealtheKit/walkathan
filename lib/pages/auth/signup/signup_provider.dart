import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../repositories/auth_repository_provider.dart';

class SignupNotifier extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData<void>(null);

  Future<void> signup({
    required String name,
    required String email,
    required String password,
    required String gender,
  }) async {
    state = const AsyncLoading<void>();

    state = await AsyncValue.guard<void>(
      () => ref
          .read(authRepositoryProvider)
          .signup(name: name, email: email, password: password, gender: gender),
    );
  }
}

final signupProvider =
    NotifierProvider<SignupNotifier, AsyncValue<void>>(SignupNotifier.new);
