import 'package:flutter/foundation.dart';
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

  /// What the nav bar draws. Zero means no badge.
  ///
  /// A notifier as well as a prefs key, because the count is now read by
  /// something that is on screen the whole time: the shade entry and the cover
  /// dot could both afford to ask the disk when they were built, and a badge
  /// beside the Chat icon cannot.
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// Message ids already counted in THIS process.
  ///
  /// The same message arrives twice by design — the realtime broadcast is the
  /// fast path and the postgres echo is the durable one — and a foreground
  /// push can make it three. Counting a message once is the difference between
  /// a badge that means something and one that inflates.
  static final Set<String> _counted = {};

  /// Count [messageId] once, for a message that arrived while the chat was not
  /// being looked at.
  static Future<void> noteUnread(String coupleId, String messageId) async {
    if (coupleId.isEmpty || !_counted.add(messageId)) return;
    count.value = await increment(coupleId);
  }

  /// Re-read the stored count into [count] — after a background push wrote it,
  /// or when the couple resolves. A null [coupleId] means there is nobody to
  /// count for, which is zero rather than "unknown".
  static Future<void> refresh(String? coupleId) async {
    if (coupleId == null || coupleId.isEmpty) {
      count.value = 0;
      return;
    }
    count.value = await current(coupleId);
  }

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
    count.value = 0;
    // Cleared too: these ids were counted only so they would not be counted
    // twice, and the tally they were counted into is gone.
    _counted.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(coupleId));
  }
}
