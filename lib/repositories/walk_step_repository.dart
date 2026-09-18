import '../constants/firebase_constants.dart';

class WalkStepRepository {

  // Helper method to generate a date key in YYYY-MM-DD format
  String _getDateKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String get _todayKey => _getDateKey(DateTime.now());

  /// Retrieves the last recorded day for a given user ID.
  Future<String?> getLastDay(String userId) async {
    try {
      final data = await supabaseClient
          .from('daily_steps')
          .select('last_day')
          .eq('user_id', userId)
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return data?['last_day'] as String?;
    } catch (e) {
      print('Error fetching last day: $e');
      return null;
    }
  }

  /// Saves the current day for a given user ID.
  Future<void> saveLastDay(String userId, String day) async {
    try {
      await supabaseClient.from('daily_steps').upsert({
        'user_id': userId,
        'date_key': _todayKey,
        'last_day': day,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,date_key');
    } catch (e) {
      print('Error saving last day: $e');
    }
  }

  /// Retrieves the last count for a given user ID for today.
  Future<int?> getLastCount(String userId) async {
    try {
      final data = await supabaseClient
          .from('daily_steps')
          .select('count')
          .eq('user_id', userId)
          .eq('date_key', _todayKey)
          .maybeSingle();
      return (data?['count'] as int?) ?? 0;
    } catch (e) {
      throw Exception("Error fetching walk steps: $e");
    }
  }

  /// Saves/updates step count for today (upsert).
  Future<void> saveStepCount(String userId, int steps, int count) async {
    try {
      await supabaseClient.from('daily_steps').upsert({
        'user_id': userId,
        'date_key': _todayKey,
        'steps': steps,
        'count': count,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,date_key');
    } catch (e) {
      print('Error saving step count: $e');
    }
  }

  /// Alias for saveStepCount — kept for API compatibility.
  Future<void> saveLastCount(String userId, int steps, int count) async {
    await saveStepCount(userId, steps, count);
  }

  /// Alias for saveStepCount — kept for API compatibility.
  Future<void> saveWalkSteps(String userId, int steps, int count) async {
    await saveStepCount(userId, steps, count);
  }

  // Get walk steps (count) for today
  Future<int> getWalkSteps(String userId) async {
    try {
      final data = await supabaseClient
          .from('daily_steps')
          .select('count')
          .eq('user_id', userId)
          .eq('date_key', _todayKey)
          .maybeSingle();
      return (data?['count'] as int?) ?? 0;
    } catch (e) {
      throw Exception("Error fetching walk steps: $e");
    }
  }

  // Update the user's steps for a specific day
  Future<void> updateUserSteps({
    required String userId,
    required int newSteps,
    required int newCount,
    required String dateKey,
  }) async {
    try {
      await supabaseClient.from('daily_steps').upsert({
        'user_id': userId,
        'date_key': dateKey,
        'steps': newSteps,
        'count': newCount,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,date_key');
    } catch (e) {
      throw Exception('Error updating user steps: $e');
    }
  }

  Future<int> getCumulativeSteps(String userId) async {
    try {
      final DateTime today = DateTime.now();
      final DateTime thirtyDaysAgo = today.subtract(const Duration(days: 30));

      final List<String> last30Days = List.generate(31, (index) {
        final date = thirtyDaysAgo.add(Duration(days: index));
        return _getDateKey(date);
      });

      final data = await supabaseClient
          .from('daily_steps')
          .select('count')
          .eq('user_id', userId)
          .inFilter('date_key', last30Days);

      int totalSteps = 0;
      for (final row in data) {
        totalSteps += (row['count'] as int?) ?? 0;
      }
      return totalSteps;
    } catch (e) {
      throw Exception('Error getting cumulative steps: $e');
    }
  }

  Future<int> getInitialStepCount(String userId) async {
    try {
      final data = await supabaseClient
          .from('daily_steps')
          .select('count')
          .eq('user_id', userId)
          .eq('date_key', _todayKey)
          .maybeSingle();
      if (data != null && data['count'] != null) {
        return data['count'] as int;
      }
    } catch (e) {
      print('Error fetching initial step count: $e');
    }
    return 0;
  }
}
