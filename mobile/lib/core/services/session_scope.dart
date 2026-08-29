import 'package:flutter/foundation.dart';
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
    final stored = await readCouple();
    // Not `_coupleId ??=`. main() does not await FcmService.init(), so this
    // races the session load, and null is BOTH "not loaded yet" and "resolved
    // to no couple" — so `??=` would let a signed-out start overwrite itself
    // with the previous account's stored couple and admit that couple's pushes.
    if (_resolved) return;
    _resolved = true;
    _coupleId = stored;
  }

  /// Whether anything has established the live couple yet, so [hydrate] knows
  /// a null it is about to overwrite is genuinely "unset" and not "no couple".
  static bool _resolved = false;

  /// Called whenever the session resolves a couple (sign-in, pairing, resume).
  ///
  /// [stillCurrent] is re-asked AFTER the prefs handle is awaited, in the same
  /// slice as the write. Asking out at the call site asks too early: the
  /// session load calls this UNAWAITED, so the row it stamps lands on the far
  /// side of a suspension the caller's own fence cannot see across — the
  /// fourth device-global publish in loadProfile that was still trusting an
  /// answer given before its own await. A refused publish leaves both the row
  /// and [_coupleId] exactly as the teardown left them.
  ///
  /// The old dedupe on `_coupleId == id` is deliberately gone. It compared the
  /// COPY against the value being written and skipped the write when they
  /// matched — but the copy is not the row, and the moment the two drift apart
  /// (a remove that threw, a write the platform dropped) the skip is permanent,
  /// because the only thing that would reconcile them is the write it skips.
  /// The foreground then reads the copy and looks correct while the background
  /// isolate reads the row — reach_notifications routes on it, the cover host
  /// draws from it — and goes on admitting the couple that left. One prefs
  /// write per session load is not a price worth a state that cannot heal.
  static Future<void> setCouple(String? id, {bool Function()? stillCurrent}) async {
    _resolved = true;
    final prefs = await SharedPreferences.getInstance();
    if (stillCurrent != null && !stillCurrent()) {
      debugPrint('[scope] setCouple abandoned: the session that asked has ended');
      return;
    }
    _coupleId = id;
    if (id == null) {
      await prefs.remove(_coupleKey);
    } else {
      await prefs.setString(_coupleKey, id);
    }
  }

  /// Drop the stored couple, and PROVE it is gone.
  ///
  /// A separate door from [setCouple] because the two ask different questions:
  /// a publish may be refused, a teardown may not. Every receiving path outside
  /// this isolate reads the ROW and not [_coupleId] — the FCM background
  /// isolate in reach_notifications, the cover host's unread dot — so a removal
  /// that quietly did not happen leaves the ex-couple's pushes admissible for
  /// the life of the install, including everything queued behind FCM's 24h TTL,
  /// with nothing on screen to say so.
  ///
  /// Read back rather than assumed: `remove` returning normally is not the same
  /// as the row being absent, and this is the one piece of teardown whose
  /// failure is invisible from inside the app. Retries before giving up, and
  /// returns whether the row is verified gone — the caller reports a false
  /// rather than treating it as done.
  static Future<bool> forgetCouple() async {
    // Before the disk work and before any retry: the foreground must stop
    // admitting that couple now, whatever the row ends up doing.
    _resolved = true;
    _coupleId = null;
    final prefs = await SharedPreferences.getInstance();
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await prefs.remove(_coupleKey);
        await prefs.reload();
        final left = prefs.getString(_coupleKey);
        if (left == null) return true;
        debugPrint('[scope] active_couple_id survived removal '
            '(attempt $attempt, still $left)');
      } catch (e) {
        debugPrint('[scope] active_couple_id removal threw '
            '(attempt $attempt): $e');
      }
      if (attempt < 3) {
        await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
      }
    }
    return false;
  }

  /// Back to the state a freshly launched process is in. A cold start is the
  /// only thing [hydrate] is for, and in a test process the statics have
  /// already been resolved by whatever ran before.
  @visibleForTesting
  static void resetForTest() {
    _coupleId = null;
    _resolved = false;
  }

  /// Read from the background isolate, which cannot see [_coupleId].
  ///
  /// Reloaded rather than read straight from the plugin's cache. The writer is
  /// the UI isolate and this reader is not, and the FCM background isolate is
  /// kept alive across several pushes — so a cache filled before the account
  /// changed answers with the couple that has left, and [forgetCouple] cannot
  /// invalidate it from the other side. UnreadTally reloads across the same
  /// boundary for the same reason.
  static Future<String?> readCouple() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload();
    } catch (e) {
      // Reported, not swallowed, and deliberately not rethrown: this runs
      // unguarded at the top of FcmService.init() and inside the background
      // handler, where a throw would take out every notification for everyone
      // — a far worse failure than the stale read it would be protesting. The
      // cached value is what this method returned before the reload existed.
      debugPrint('[scope] prefs reload failed ($e) — reading the cached row');
    }
    return prefs.getString(_coupleKey);
  }

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
