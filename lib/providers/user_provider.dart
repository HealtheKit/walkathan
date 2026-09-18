import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user_model.dart';
import '../services/user_service.dart';

final userServiceProvider = Provider<UserService>((ref) => UserService());

class UserNotifier extends Notifier<UserModel?> {
  @override
  UserModel? build() => null;

  void setUser(UserModel? user) => state = user;
}

final userProvider = NotifierProvider<UserNotifier, UserModel?>(UserNotifier.new);

final userListProvider = FutureProvider<List<UserModel>>((ref) async {
  return ref.watch(userServiceProvider).getAllUsers();
});