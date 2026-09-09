import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:miles/core/data/secure_storage_options.dart';

/// Trust-on-first-use for the partner's published X25519 key.
///
/// `partner_keys` is a directory the server controls. Every E2EE guarantee in
/// this app reduced to "the server hands back the key it was given" — a
/// compromised or coerced database could substitute its own key and quietly
/// become the second member of any couple, for all future content. The pin is
/// the client's own memory of which key it has been talking to: stored on
/// first sight, checked on every derive, and a change REFUSES to proceed until
/// a human has said the change is real.
///
/// Legitimate changes exist — a reinstall or new phone mints a new keypair —
/// and both arrive through doors that already prove a human: the rewrap
/// ceremony verifies a six-digit code read over a call (it repins
/// automatically), and the change sheet asks the couple to compare the
/// [safetyCode] aloud before it repins. What can never repin is silence.
class PartnerKeyPin {
  PartnerKeyPin._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: kMilesKeychain,
  );

  /// Scoped by BOTH ids: the pin is one account's memory of one partner, and
  /// a handset that changes accounts must not inherit or overwrite another
  /// account's memory. (The value is a hash of a public key — not a secret —
  /// but it is a TRUST ROOT, which is a better reason to keep it in the
  /// keystore than secrecy: anything that can rewrite it can unpin.)
  static String _key(String myUid, String partnerId) =>
      'partner_key_pin_v1:$myUid:$partnerId';

  /// A key the ceremony has verified but the partner has not published yet.
  /// See [expect].
  static String _expectKey(String myUid, String partnerId) =>
      'partner_key_expect_v1:$myUid:$partnerId';

  static String _digest(String partnerPubB64) =>
      sha256.convert(base64Decode(partnerPubB64)).toString();

  /// The verdict on a fetched partner key, against this device's memory.
  static Future<PinCheck> check({
    required String myUid,
    required String partnerId,
    required String partnerPubB64,
  }) async {
    final key = _key(myUid, partnerId);
    final pinned = await _storage.read(key: key);
    final seen = _digest(partnerPubB64);
    if (pinned == null) {
      // First sight. TOFU's one honest weakness: a server that lies from the
      // very first fetch is undetectable — but from this moment on it cannot
      // change its story without a human noticing.
      await _storage.write(key: key, value: seen);
      return PinCheck.firstUse;
    }
    if (pinned == seen) return PinCheck.match;
    // A change the ceremony announced in advance is not an alarm — it is the
    // rotation arriving. Consume the expectation so it can authorise exactly
    // one change, exactly the one the digits verified.
    final expectKey = _expectKey(myUid, partnerId);
    final expected = await _storage.read(key: expectKey);
    if (expected != null && expected == seen) {
      await _storage.write(key: key, value: seen);
      await _storage.delete(key: expectKey);
      return PinCheck.match;
    }
    return PinCheck.mismatch;
  }

  /// Record that [partnerPubB64] is ABOUT to become the partner's key.
  ///
  /// The rewrap ceremony's answering phone calls this after the voice code —
  /// Argon2id-committed to exactly this key — has passed and the sealed
  /// answer has landed. The partner deliberately publishes only when they
  /// CLAIM the answer, so repinning here would say NEW while the directory
  /// still serves OLD and raise the change alarm against the partner's own
  /// legitimate key. An expectation instead: the pin stays with the
  /// directory, and the first fetch that returns this exact key repins
  /// silently in [check].
  static Future<void> expect({
    required String myUid,
    required String partnerId,
    required String partnerPubB64,
  }) =>
      _storage.write(
        key: _expectKey(myUid, partnerId),
        value: _digest(partnerPubB64),
      );

  /// Accept [partnerPubB64] as the partner's key from here on.
  ///
  /// Only two callers may exist: the rewrap ceremony after its voice-verified
  /// AEAD open succeeds, and the change sheet after the user confirms the
  /// safety codes match. Adding a third caller that repins without a human in
  /// the loop deletes the entire point of this class.
  static Future<void> repin({
    required String myUid,
    required String partnerId,
    required String partnerPubB64,
  }) =>
      _storage.write(
        key: _key(myUid, partnerId),
        value: _digest(partnerPubB64),
      );

  /// A short code both phones can read aloud, equal exactly when both derive
  /// from the same two public keys. Sorted before hashing so both sides
  /// compute the identical code without agreeing who goes first.
  ///
  /// Twenty digits in four groups — 66 bits of the hash, far past what a
  /// substituted key could collide by luck, short enough to actually be read
  /// over a call.
  static String safetyCode(String pubA64, String pubB64) {
    final a = base64Decode(pubA64);
    final b = base64Decode(pubB64);
    final sorted = _compareBytes(a, b) <= 0 ? [...a, ...b] : [...b, ...a];
    final h = sha256.convert(sorted).bytes;
    final sb = StringBuffer();
    for (var i = 0; i < 20; i++) {
      sb.write(h[i] % 10);
      if (i % 5 == 4 && i != 19) sb.write(' ');
    }
    return sb.toString();
  }

  static int _compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}

enum PinCheck { firstUse, match, mismatch }

/// Thrown instead of deriving when the fetched key contradicts the pin.
///
/// Carries what the change sheet needs and nothing it must not: ids and the
/// NEW public key (public material). The sheet decides whether a human said
/// yes; nothing catches this to swallow it.
class PartnerKeyChangedException implements Exception {
  PartnerKeyChangedException({
    required this.partnerId,
    required this.newKeyB64,
  });

  final String partnerId;
  final String newKeyB64;

  @override
  String toString() => 'PartnerKeyChangedException';
}
