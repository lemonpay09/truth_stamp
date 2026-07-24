import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class UsageLimitDecision {
  const UsageLimitDecision({
    required this.role,
    required this.todayCount,
    required this.allowed,
  });

  final String role;
  final int todayCount;
  final bool allowed;
}

class UsageLimitService {
  const UsageLimitService();

  static const int freeDailyLimit = 5;

  Future<UsageLimitDecision> evaluate() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    final userId = user?.id ?? 'guest';
    final role = await _fetchRole(userId: userId, user: user, client: client);
    final count = await _todayCount(userId);
    final allowed = role != 'Free' || count < freeDailyLimit;
    return UsageLimitDecision(role: role, todayCount: count, allowed: allowed);
  }

  Future<void> consume(UsageLimitDecision decision) async {
    if (decision.role != 'Free') return;
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id ?? 'guest';
    final prefs = await SharedPreferences.getInstance();
    final key = _dailyKey(userId);
    final next = (prefs.getInt(key) ?? 0) + 1;
    await prefs.setInt(key, next);
  }

  Future<String> _fetchRole({
    required String userId,
    required User? user,
    required SupabaseClient client,
  }) async {
    if (user == null) return 'Free';
    final metadataRole = user.userMetadata?['role']?.toString();
    try {
      final row = await client
          .from('app_users')
          .select('role')
          .eq('user_id', userId)
          .maybeSingle();
      final dbRole = row?['role']?.toString();
      if (dbRole != null && dbRole.isNotEmpty) return dbRole;
    } on PostgrestException {
      // Fallback to user metadata/default when table policy not configured.
    }
    return (metadataRole == null || metadataRole.isEmpty) ? 'Free' : metadataRole;
  }

  Future<int> _todayCount(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_dailyKey(userId)) ?? 0;
  }

  String _dailyKey(String userId) {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return 'daily_verify_count_${userId}_$y$m$d';
  }
}
