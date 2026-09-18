import '../models/user_model.dart';
import '../constants/firebase_constants.dart';

class UserRepository {

  Future<void> addUser(UserModel user) async {
    await supabaseClient.from('users').upsert(user.toJson());
  }

  Future<List<UserModel>> getAllUsers() async {
    final data = await supabaseClient.from('users').select();
    return data.map((row) => UserModel.fromJson(row)).toList();
  }
}