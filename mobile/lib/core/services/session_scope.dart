import 'package:shared_preferences/shared_preferences.dart';

/// Which couple this handset is currently signed in as.
///
/// A push is addressed to a TOKEN, and a token is a property of the device, not
/// of the account — so nothing in the delivery path guarantees that what FCM
/// hands this handset belongs to whoever is signed in on it right now. It did
/// not: one handset held the same token on two profiles in two different
/// couples, and a Reach belonging to the second account was delivered into the
/// first account's session.
///
/// The server no longer lets one token sit on two profiles, but a push already
/// in flight, or queued behind a 24h message TTL, can still land after the
/// account on the handset has changed. So every receiving path — the background
/// isolate, the foreground handler, the notification tap — checks the push's
/// couple_id against this before acting on it.
///
/// Stored in SharedPreferences because the background isolate has no session,
/// no Supabase client and no memory shared with the UI isolate; mirrored in a
/// static so the foreground can check without an await on every push.
class SessionScope {
  SessionScope._();

  static const _coupleKey = 'active_couple_id';

  /// The UI isolate's copy. Null means "not loaded yet or signed out" — both of
  /// which must reject a foreign push, so callers treat null as "no match".
  static String? _coupleId;

  static String? get coupleId => _coupleId;

  /// Load the stored couple into memory before anything routes a push.
  ///
  /// A cold start from a tapped notification runs before the session has
  /// loaded, so without this the live couple would read null and the tap that
  /// launched the app would be discarded as foreign — the guard would break the
  /// exact case it exists to protect.
  static Future<void> hydrate() async {
    _coupleId ??= await readCouple();
  }

  /// Called whenever the session resolves a couple (sign-in, pairing, resume).
  static Future<void> setCouple(String? id) async {
    if (_coupleId == id) return;
    _coupleId = id;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_coupleKey);
    } else {
      await prefs.setString(_coupleKey, id);
    }
  }

  /// Read from the background isolate, which cannot see [_coupleId].
  static Future<String?> readCouple() async =>
      (await SharedPreferences.getInstance()).getString(_coupleKey);

  /// Whether a push carrying [pushCoupleId] may be acted on.
  ///
  /// A push with no couple_id is allowed through: it predates this field and
  /// dropping it would silently kill notifications for anyone whose build, or
  /// whose queued message, is older than this change. Everything the server
  /// sends now carries one.
  static bool allows(String? pushCoupleId, String? activeCoupleId) {
    if (pushCoupleId == null || pushCoupleId.isEmpty) return true;
    return pushCoupleId == activeCoupleId;
  }
}
