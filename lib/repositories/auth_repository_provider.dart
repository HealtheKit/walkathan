import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/firebase_constants.dart';
import 'auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository();
});

final authStateStreamProvider = StreamProvider<AuthState>((ref) {
  return supabaseClient.auth.onAuthStateChange;
});
