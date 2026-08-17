import 'package:cryptography/cryptography.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Why one memory could not be opened, decided WHERE THE DECRYPT HAPPENS.
///
/// `CloserLoadResult.unreadable` only ever counted `fromJson` throwing on a
/// malformed `bytea`. The decrypt runs later and lazily, per widget, so a MAC
/// failure — the one cause that is permanent — was never classified at all,
/// and every cause alike rendered `'Could not decrypt: $e'`.
///
/// The distance between these is the distance between "wait" and "this is
/// gone", so each carries its own sentence rather than a shared apology.
sealed class MemoryFailure implements Exception {
  const MemoryFailure();

  /// Classify a failure decrypting ciphertext that came out of the ROW:
  /// `title_cipher`, `note_cipher`, the legacy inline `photo_cipher`. Those
  /// bytes arrive over TLS from Postgres and their associated data is the item
  /// id, so a MAC failure here is the key and nothing else.
  factory MemoryFailure.ofRow(Object error) {
    if (error is SecretBoxAuthenticationError) return const KeyGoneForever();
    return _shared(error);
  }

  /// Classify a failure decrypting a storage OBJECT: a cover, a tile, a full.
  ///
  /// Deliberately cannot produce [KeyGoneForever]. A MAC failure on a
  /// downloaded object is produced identically by a truncated download, a
  /// byte-flipped disk-cache entry or a wrong associated data, and none of
  /// those has earned the right to tell someone their photograph is gone from
  /// both phones for good.
  factory MemoryFailure.ofObject(Object error) {
    if (error is SecretBoxAuthenticationError) {
      return const MemoryMediaFailure(MediaTransient());
    }
    return _shared(error);
  }

  static MemoryFailure _shared(Object error) {
    // The pin refused a changed partner key. BY TYPE and FIRST: its toString
    // carries no sentence, so it used to fall through to the generic apology
    // with a retry that can never succeed — over the one refusal here that
    // has its own resolution, one screen away.
    if (error is PartnerKeyChangedException) return const PartnerKeyChanged();
    // An encrypted value with no derived couple key (the no-key StateErrors
    // in crypto_core's encrypt/decrypt paths). Nothing on this device is
    // wrong and nothing here can fix it.
    if (error is StateError) return const KeyNotYetShared();
    if (error is MediaFailure) return MemoryMediaFailure(error);
    return const MemoryUnavailable();
  }

  String get message;
}

/// The partner has not published a key yet, so nothing they wrote opens.
///
/// `ensureSharedKey` re-derives on every Closer entry, so this resolves itself
/// the moment she opens the app — which is why it offers no action.
class KeyNotYetShared extends MemoryFailure {
  const KeyNotYetShared();

  @override
  String get message => 'Waiting for your partner. This opens by itself once '
      "she's opened Closer on her phone.";
}

/// The pin refused a changed partner key. Deliberately not resolvable from
/// here: the review sheet lives on the Closer entry, which is one tap away
/// and is the one place the couple compares the safety code.
class PartnerKeyChanged extends MemoryFailure {
  const PartnerKeyChanged();

  @override
  String get message => "Your partner's security key changed. Open Closer to "
      'review it before anything is written or read.';
}

/// Encrypted under a key that exists nowhere any more.
///
/// A reinstall wipes `FlutterSecureStorage`, so the device mints a fresh
/// keypair and `publishMyPublicKey` upserts OVER the published one — after
/// which `ensureSharedKey` re-derives the shared secret from the new key on
/// BOTH phones. So this is not "unreadable on this device": her copy is
/// unreadable too, permanently. Telling her to open Closer would be advice
/// that cannot work, which is why the sentence says so outright.
class KeyGoneForever extends MemoryFailure {
  const KeyGoneForever();

  @override
  String get message => 'Locked to an old install. This was encrypted with a '
      "key that was on your phone before you reinstalled. It can't be opened "
      'here — or on hers.';
}

/// A [MediaFailure] carried through this taxonomy rather than restated in it.
///
/// `encrypted_media_cache.dart` already owns the difference between "try
/// again" and "the file is gone", and owns the sentence for each. A second
/// definition here would be one that could drift from the one doing the
/// throwing.
class MemoryMediaFailure extends MemoryFailure {
  const MemoryMediaFailure(this.cause);

  final MediaFailure cause;

  @override
  String get message => cause.message;
}

/// Nothing above matched: a dropped socket, a timeout, a PostgrestException on
/// the row re-read. The one class that must never sound permanent, because it
/// does not know whether it is.
class MemoryUnavailable extends MemoryFailure {
  const MemoryUnavailable();

  @override
  String get message => "Couldn't open this one. Try again.";
}

/// What to say when a Closer screen could not get as far as reading anything.
///
/// `ensureSharedKey` signals the two states a person can act on by throwing a
/// SENTENCE (`closer_crypto.dart:24,32,46`), and its callers rendered whatever
/// came back with `e.toString().replaceFirst('Exception: ', '')`. So the other
/// two things it can throw — a `StateError` about a malformed partner key, a
/// `PostgrestException` from the key-publish round trip — printed themselves,
/// SQLSTATE and hint included, at the user. Matched on here, never returned.
String partnerKeyMessage(Object error) {
  // By type, ahead of the string probes: its toString carries no sentence.
  if (error is PartnerKeyChangedException) {
    return const PartnerKeyChanged().message;
  }
  final raw = error is PostgrestException ? error.message : error.toString();
  if (raw.contains("hasn't enabled Closer")) {
    return const KeyNotYetShared().message;
  }
  if (raw.contains('Link your partner')) return 'Link your partner to use this.';
  return "That didn't go through. Try again.";
}
