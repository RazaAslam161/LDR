import 'package:shared_preferences/shared_preferences.dart';

/// How many messages have arrived since the owner last looked.
///
/// Exists so the shade carries ONE entry per conversation that counts up,
/// instead of one entry per message. Thirty messages over lunch used to be
/// thirty notifications: for a cover pretending to be a weather app, the
/// frequency is the tell long before the wording is.
///
/// Backed by SharedPreferences because the FCM background isolate is where this
/// is written, and it has no access to app state — only to disk.
class UnreadTally {
  UnreadTally._();

  static String _key(String coupleId) => 'miles_unread_$coupleId';

  /// Counts one more, and returns the new total.
  ///
  /// Reads immediately before writing rather than caching: the background
  /// isolate is torn down between pushes, so anything held in memory here is
  /// gone by the next message.
  static Future<int> increment(String coupleId) async {
    if (coupleId.isEmpty) return 1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final next = (prefs.getInt(_key(coupleId)) ?? 0) + 1;
    await prefs.setInt(_key(coupleId), next);
    return next;
  }

  static Future<int> current(String coupleId) async {
    if (coupleId.isEmpty) return 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(_key(coupleId)) ?? 0;
  }

  /// The owner has seen them. Called when the chat opens, which is also what
  /// clears the notification — the two must happen together or the count
  /// resumes from a number the shade no longer shows.
  static Future<void> clear(String coupleId) async {
    if (coupleId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(coupleId));
  }
}
