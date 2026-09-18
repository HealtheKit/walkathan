import '../repositories/user_repository.dart';
import '../models/user_model.dart';

class UserService {
  final UserRepository _userRepository = UserRepository();

  Future<void> addUser(UserModel user) async {
    await _userRepository.addUser(user);
  }

  Future<List<UserModel>> getAllUsers() async {
    return await _userRepository.getAllUsers();
  }
}