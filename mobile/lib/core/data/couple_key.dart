import 'package:flutter/foundation.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/data/supabase_repository.dart';

/// Makes the couple's shared key available to paths that are NOT Closer.
///
/// `ensureSharedKey` (closer_crypto.dart) is the loud version: it throws so a
/// Closer screen can put a reason on the glass. Chat cannot use it. Chat works
/// today with no key at all, and it has to keep working that way on every
/// build that is already in the field — so this answers with a bool and never
/// throws.
///
/// It exists because the key was only ever derived where Closer had already
/// prepared it. `deriveSharedKey` is called from Closer, the wish jar, memory
/// threads and the rewrap screen and from nowhere else; `_sharedKey` is
/// in-memory and `bindAccount` clears it on every cold start; and
/// `couples.modest_mode` DEFAULTS TO TRUE while closer_screen.dart:45 returns
/// before key prep whenever it is on. So the ordinary couple — one that never
/// turned modest mode off — has no published key and no derived key, and any
/// feature outside Closer that tried to encrypt would fail for them while
/// working perfectly on a developer's own paired handsets.
class CoupleKey {
  CoupleKey._();

  /// Publishing is idempotent but costs a select plus an upsert, and the chat
  /// re-runs this on every open. Once per session is enough: a reinstall is a
  /// new process, and a sign-out resets it below — the next account must
  /// publish its OWN key, not skip the upsert on the strength of this one's.
  static bool _publishedThisProcess = false;

  /// The one in-flight derive for this process.
  ///
  /// Everything that needs the key awaits THIS rather than starting its own:
  /// the derive is three round trips and a pin check, and a chat open used to
  /// fire it unawaited while the send path raced ahead without it. Whoever asks
  /// first starts it; everyone after joins the same future.
  static Future<bool>? _ready;

  /// Session-scoped, not process-scoped. _endSession calls this: a memoized
  /// derive that survived sign-out answered the NEXT account's chat with the
  /// previous account's verdict — encryption silently off (and incoming
  /// cipher rows unreadable) until process death.
  static void reset() {
    _publishedThisProcess = false;
    _ready = null;
  }

  @visibleForTesting
  static void resetForTest() => reset();

  /// Start (or join) the derive. Safe to call on every session refresh.
  ///
  /// A completed FALSE un-memoizes itself: false is the ordinary mid-setup
  /// answer, but it is also what a transient network failure returns — and a
  /// false held for the life of the process turned one bad moment into a
  /// whole session of plaintext. Retry is still single-flight: the future is
  /// only cleared after it completes, so concurrent callers keep joining the
  /// one in-flight derive.
  static Future<bool> prime(SessionState session) {
    return _ready ??= ensure(session).then((ok) {
      if (!ok) _ready = null;
      return ok;
    });
  }

  /// Await the derive already in flight, if there is one.
  ///
  /// False without starting anything when the session has never had a partner —
  /// the caller has no session to hand over and must carry on unencrypted. This
  /// is what lets ChatRepository wait for the key without reaching for a
  /// Riverpod provider from the data layer.
  static Future<bool> ready() async => await _ready ?? false;

  /// Derives the couple key if it can be derived. True when a key is available
  /// afterwards.
  ///
  /// False is an ordinary answer, not a failure: a partner who has not
  /// published yet is the normal state of a couple mid-setup. Callers must
  /// treat false as "no encryption available right now" and carry on.
  static Future<bool> ensure(SessionState session) async {
    // Already derived in this process — the common case after the first open.
    if (await CryptoCore.exportSharedKeyBytes() != null) return true;

    final me = session.profile;
    final partner = session.partner;
    if (me == null || partner == null) return false;

    try {
      if (!_publishedThisProcess) {
        // Self-guards against a rewrap in flight (supabase_repository.dart:461):
        // publishing mid-ceremony would rotate the key the partner is sealing
        // against. Not our decision to make here.
        await SupabaseRepository.publishMyPublicKey();
        _publishedThisProcess = true;
      }

      final partnerPub =
          await SupabaseRepository.fetchPartnerPublicKey(partner.id);
      // fetchPartnerPublicKey never returns null — it returns the sentinel —
      // and deriveSharedKey now THROWS on the sentinel rather than dropping to
      // plaintext. Refuse it here, like every other caller, so the ordinary
      // "partner hasn't opened the app yet" state is a quiet false and not a
      // logged error.
      if (partnerPub == null || partnerPub == CryptoCore.legacyPublicKey) {
        return false;
      }

      // The pin guards every door into the derive or it guards none of them —
      // this is the door the chat opens on every launch, and without the
      // check here a substituted directory key would be derived and USED
      // silently while Closer's own entry was busy refusing it. Chat's
      // contract is bool-never-throw, so a mismatch is a quiet false (no
      // encryption available) — the sheet that resolves it lives on the
      // Closer entry, which raises it loudly.
      final verdict = await PartnerKeyPin.check(
        myUid: me.id,
        partnerId: partner.id,
        partnerPubB64: partnerPub,
      );
      if (verdict == PinCheck.mismatch) {
        debugPrint('[key] partner key mismatch — refusing to derive');
        return false;
      }

      await CryptoCore.deriveSharedKey(partnerPublicKeyB64: partnerPub);
      return true;
    } catch (e) {
      // Never swallowed silently: a corrupt or wrong-length partner key makes
      // deriveSharedKey throw, and that is the difference between "encryption
      // is off" and "encryption is off and nobody knows why".
      debugPrint('[key] couple key unavailable: ${e.runtimeType} $e');
      return false;
    }
  }
}
