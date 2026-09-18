import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../constants/firebase_constants.dart';

class LeaderboardRepository {

  String _getDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<List<Map<String, dynamic>>> getTopUsersBySteps(String filterGender) async {
    const int days = 30;
    try {
      final DateTime today = DateTime.now();
      final DateTime startDate = today.subtract(const Duration(days: days - 1));

      final List<String> dateKeys = List.generate(days, (index) {
        return _getDateKey(startDate.add(Duration(days: index)));
      });

      // Get all users of the specified gender
      final users = await supabaseClient
          .from('users')
          .select('id, name')
          .eq('gender', filterGender);

      if (users.isEmpty) return [];

      final userIds = users.map((u) => u['id'] as String).toList();

      // Get all daily_steps for these users in the date range in one query
      final stepsData = await supabaseClient
          .from('daily_steps')
          .select('user_id, count')
          .inFilter('user_id', userIds)
          .inFilter('date_key', dateKeys);

      // Aggregate steps per user
      final Map<String, int> stepsByUser = {};
      for (final row in stepsData) {
        final uid = row['user_id'] as String;
        final count = (row['count'] as int?) ?? 0;
        stepsByUser[uid] = (stepsByUser[uid] ?? 0) + count;
      }

      // Build result list
      final List<Map<String, dynamic>> usersWithSteps = users.map((user) {
        final uid = user['id'] as String;
        return {
          'userId': uid,
          'name': user['name']?.toString() ?? 'Anonymous',
          'totalSteps': stepsByUser[uid] ?? 0,
        };
      }).toList();

      // Sort descending and take top 5
      usersWithSteps.sort((a, b) => (b['totalSteps'] as int).compareTo(a['totalSteps'] as int));
      return usersWithSteps.take(5).toList();
    } catch (e) {
      throw Exception('Error getting top users by steps: $e');
    }
  }
}

final leaderboardRepositoryProvider = Provider<LeaderboardRepository>((ref) => LeaderboardRepository());

final leaderboardMaleDataProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final repo = ref.watch(leaderboardRepositoryProvider);
  return await repo.getTopUsersBySteps('male');
});

final leaderboardFeMaleDataProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final repo = ref.watch(leaderboardRepositoryProvider);
  return await repo.getTopUsersBySteps('female');
});