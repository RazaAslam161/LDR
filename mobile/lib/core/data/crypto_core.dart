import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Couple-shared authenticated encryption for the Closer module.
///
/// History: real E2EE was stripped in 2026-06 back when this was a private
/// two-person app, and encrypt/decrypt became base64 pass-throughs. Shipping
/// to strangers put every intimate note and photo in the database as plaintext,
/// so real AEAD is back — but rolled in without breaking a single existing row.
///
/// Two rules make that safe:
///
///   1. OPPORTUNISTIC. A message is only encrypted once BOTH partners have
///      published a real X25519 key. Until then [encryptBytes] writes the same
///      zero-nonce base64 shape it always did, so nothing breaks while one side
///      is still on the old build.
///
///   2. SELF-DESCRIBING ON READ. A legacy (or plaintext-mode) row carries an
///      all-zero nonce and all-zero MAC; a real row never does. [decryptBytes]
///      branches on that, so old plaintext rows keep reading forever alongside
///      new encrypted ones.
///
/// Key exchange: each device holds one X25519 private key in the platform
/// keystore (never leaves the device, never backed up), publishes its public
/// key through `partner_keys`, and derives a shared key by ECDH + HKDF. The
/// shared key is session-cached and never persisted.
class CryptoCore {
  CryptoCore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _privKeyStoreKey = 'miles_x25519_priv_v1';

  /// Which account claimed the pre-migration, unscoped seed. See [bindAccount].
  static const _legacySeedOwnerKey = 'miles_x25519_legacy_owner';

  /// The signed-in account the in-memory key material belongs to.
  ///
  /// The seed used to be stored under one device-wide key, so signing out and
  /// signing in as somebody else handed the new account the previous account's
  /// private key — it would publish that identity as its own and escrow it
  /// under its own password. Scoping storage per account is what stops that.
  /// Deliberately *not* deleting on sign-out: an account that never wrote an
  /// escrow row has no other copy of its key, so erasing it would destroy the
  /// history it protects.
  static String? _accountId;

  static String get _seedKey =>
      _accountId == null ? _privKeyStoreKey : '${_privKeyStoreKey}_$_accountId';

  /// The public-key value the old build published for everyone. A partner
  /// still advertising this has no real key, so we cannot encrypt to them yet.
  static const legacyPublicKey = 'plaintext-v1';

  static final _x25519 = X25519();
  static final _aead = Xchacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static SimpleKeyPair? _myKeyPair;

  /// The derived couple key. Null means plaintext mode — the partner has not
  /// published a real key yet, so writes stay in the legacy shape.
  static SecretKey? _sharedKey;

  /// True only when the partner explicitly published [legacyPublicKey].
  ///
  /// Guards the plaintext branch in [encryptBytes]. A null [_sharedKey] alone
  /// used to be enough to write cleartext, which meant every failure path —
  /// corruption, a cleared cache, a key not derived yet — silently disabled
  /// encryption. Now only an explicit agreement does.
  static bool _plaintextAgreed = false;

  /// Bumped every time the key this device decrypts with could have changed.
  ///
  /// Plaintext caches key themselves on this, and listen to it so they can
  /// CLEAR rather than merely re-key. Both halves matter:
  ///
  ///   Re-keying alone leaves the old plaintext reachable in the map forever —
  ///   correct, but it protects neither memory nor the threat model.
  ///
  ///   Not bumping at all is worse. [VaultMediaCache] keys by a per-PROCESS id,
  ///   so after an escrow restore mid-session it kept serving bytes decrypted
  ///   under the key that was just replaced.
  static final ValueNotifier<int> keyEpoch = ValueNotifier<int>(0);

  static void _bumpEpoch() => keyEpoch.value++;

  /// Point key material at [uid], migrating a pre-scoping seed exactly once.
  ///
  /// The unscoped seed belongs to whoever was signed in when this build landed,
  /// so the first account to bind after upgrading claims it and every later one
  /// starts fresh. At sign-in this runs after an escrow restore, so a recovered
  /// seed is already in place and the claim is skipped.
  static Future<void> bindAccount(String uid) async {
    if (_accountId == uid) return;
    _accountId = uid;
    _myKeyPair = null;
    _sharedKey = null;
    _plaintextAgreed = false;
    _derivedFrom = null;

    if (await _storage.read(key: _seedKey) == null) {
      final owner = await _storage.read(key: _legacySeedOwnerKey);
      final legacy = await _storage.read(key: _privKeyStoreKey);
      if (legacy != null && owner == null) {
        await _storage.write(key: _legacySeedOwnerKey, value: uid);
        await _storage.write(key: _seedKey, value: legacy);
      }
    }
    _bumpEpoch();
  }

  /// Sign-out. Drops every decrypted byte and every key still held in memory;
  /// the account's sealed seed stays in storage so signing back in works
  /// offline. See [_accountId] for why this does not delete.
  static void forgetAccount() {
    _accountId = null;
    _myKeyPair = null;
    _sharedKey = null;
    _plaintextAgreed = false;
    _derivedFrom = null;
    _bumpEpoch();
  }

  static Future<SimpleKeyPair> _keyPair() async {
    if (_myKeyPair != null) return _myKeyPair!;
    final stored = await _storage.read(key: _seedKey);
    if (stored != null) {
      _myKeyPair = await _x25519.newKeyPairFromSeed(base64Decode(stored));
    } else {
      final kp = await _x25519.newKeyPair();
      final data = await kp.extract();
      await _storage.write(key: _seedKey, value: base64Encode(data.bytes));
      _myKeyPair = kp;
    }
    return _myKeyPair!;
  }

  /// The raw private seed, for [KeyEscrow] to seal under the user's password.
  ///
  /// Deliberately narrow: this is the ONLY way the seed leaves this class, and
  /// the one caller wraps it before it touches the network.
  static Future<Uint8List?> exportPrivateSeed() async {
    final stored = await _storage.read(key: _seedKey);
    if (stored == null) return null;
    return Uint8List.fromList(base64Decode(stored));
  }

  /// Install a seed recovered from escrow, replacing whatever is local.
  ///
  /// Clears the derived shared key too: it was computed from the keypair being
  /// replaced, and leaving it would decrypt with the wrong key while looking
  /// perfectly healthy.
  static Future<void> adoptPrivateSeed(Uint8List seed) async {
    await _storage.write(key: _seedKey, value: base64Encode(seed));
    _myKeyPair = await _x25519.newKeyPairFromSeed(seed);
    _sharedKey = null;
    _plaintextAgreed = false;
    _derivedFrom = null;
    // Immediately, not on the next derive: an escrow restore mid-session means
    // every plaintext already in memory was decrypted under the key this call
    // just replaced.
    _bumpEpoch();
  }

  /// This device's X25519 public key, base64. Published through `partner_keys`.
  static Future<String> getMyPublicKeyB64() async {
    final pub = await (await _keyPair()).extractPublicKey();
    return base64Encode(pub.bytes);
  }

  /// Derives the shared couple key from the partner's published public key.
  ///
  /// Falls back to plaintext mode — not an error — when the partner has no
  /// real key yet ([legacyPublicKey], a malformed value, or the wrong length).
  /// That keeps Closer fully working during the window where one partner has
  /// upgraded and the other has not.
  static Future<void> deriveSharedKey({
    required String partnerPublicKeyB64,
  }) async {
    // The ONLY value that may turn encryption off. It is a deliberate sentinel
    // meaning "my partner is on a build with no key yet", and plaintext there
    // is a considered decision.
    if (partnerPublicKeyB64 == legacyPublicKey) {
      _plaintextAgreed = true;
      _sharedKey = null;
      if (_derivedFrom != null) {
        _derivedFrom = null;
        _bumpEpoch();
      }
      return;
    }

    // Everything below is a partner who DOES have a key. If it cannot be read,
    // that is corruption — a truncated column, a bad write, a tampered row —
    // and it must not silently take the same exit as the sentinel above.
    //
    // It used to. A malformed or wrong-length key set _sharedKey = null and
    // returned NORMALLY, and encryptBytes with a null key emits zero-nonce,
    // zero-MAC cleartext. So one bad byte in partner_keys silently turned
    // encryption off for every subsequent write, on an app whose entire premise
    // is that its contents cannot be read, and nothing anywhere said so.
    // Encryption must fail closed.
    _plaintextAgreed = false;
    Uint8List partnerPub;
    try {
      partnerPub = base64Decode(partnerPublicKeyB64);
    } catch (_) {
      _sharedKey = null;
      throw StateError('partner key is not valid base64 — refusing to '
          'downgrade to plaintext');
    }
    if (partnerPub.length != 32) {
      _sharedKey = null;
      throw StateError('partner key is ${partnerPub.length} bytes, expected 32 '
          '— refusing to downgrade to plaintext');
    }

    final shared = await _x25519.sharedSecretKey(
      keyPair: await _keyPair(),
      remotePublicKey: SimplePublicKey(partnerPub, type: KeyPairType.x25519),
    );
    _sharedKey = await _hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode('miles-closer-v1'),
    );
    // ensureSharedKey runs on every Closer entry, so bumping unconditionally
    // here would clear every plaintext cache several times a session for a key
    // that did not move. Only a DIFFERENT partner key is a new epoch.
    if (_derivedFrom != partnerPublicKeyB64) {
      _derivedFrom = partnerPublicKeyB64;
      _bumpEpoch();
    }
  }

  /// The partner public key [_sharedKey] was last derived from, so a repeat
  /// derivation of the same key is recognised as a no-op.
  static String? _derivedFrom;

  static void clearCache() {
    _sharedKey = null;
    // Reset with it. A cleared cache is "we do not know yet", never "write
    // cleartext" — and this is the state after sign-out.
    _plaintextAgreed = false;
    _derivedFrom = null;
    // Sign-out. Every decrypted byte still held anywhere belongs to the account
    // that just left.
    _bumpEpoch();
  }

  static Future<List<int>?> exportSharedKeyBytes() async {
    if (_sharedKey == null) return null;
    return _sharedKey!.extractBytes();
  }

  static bool _isLegacy(Uint8List nonce, Uint8List mac) =>
      nonce.every((b) => b == 0) && mac.every((b) => b == 0);

  static Future<EncryptedPayload> encryptString(
    String plaintext, {
    String? associatedData,
  }) =>
      encryptBytes(utf8.encode(plaintext), associatedData: associatedData);

  /// What an isolate needs to encrypt without touching this class's state.
  ///
  /// A SecretKey cannot cross an isolate boundary, so the raw bytes are
  /// exported once on the caller's side and the isolate rebuilds the key.
  static Future<EncryptedPayload> encryptBytesOffThread(
    Uint8List bytes, {
    String? associatedData,
  }) async {
    final keyBytes = await exportSharedKeyBytes();
    // No key means plaintext mode, which is a base64 encode and nothing else —
    // not worth an isolate spawn.
    if (keyBytes == null) {
      return encryptBytes(bytes, associatedData: associatedData);
    }
    // Small payloads cost more to ship across the boundary than to encrypt.
    if (bytes.length < 256 * 1024) {
      return encryptBytes(bytes, associatedData: associatedData);
    }
    return compute(
      _isolateEncrypt,
      _EncryptRequest(bytes, associatedData, keyBytes),
    );
  }

  static Future<EncryptedPayload> encryptBytes(
    List<int> bytes, {
    String? associatedData,
  }) async {
    final key = _sharedKey;
    if (key == null) {
      // Cleartext ONLY where the partner published the plaintext sentinel.
      // Without this check any state with no derived key — a cleared cache, a
      // failed derivation, a race before pairing — wrote unencrypted content
      // into a database whose whole point is that it holds none.
      if (!_plaintextAgreed) {
        throw StateError(
          'no shared key — refusing to write unencrypted content',
        );
      }
      return EncryptedPayload(
        ciphertextB64: base64Encode(bytes),
        nonceB64: base64Encode(Uint8List(_nonceLength)),
        macB64: base64Encode(Uint8List(_macLength)),
      );
    }
    final box = await _aead.encrypt(
      bytes,
      secretKey: key,
      nonce: _aead.newNonce(),
      aad: associatedData == null ? const <int>[] : utf8.encode(associatedData),
    );
    return EncryptedPayload(
      ciphertextB64: base64Encode(box.cipherText),
      nonceB64: base64Encode(box.nonce),
      macB64: base64Encode(box.mac.bytes),
    );
  }

  /// Decrypts a `nonce || mac || ciphertext` blob — `packFull` output — off the
  /// UI isolate, without a base64 round trip.
  ///
  /// [VaultMediaCache] goes through [EncryptedPayload], whose three fields are
  /// base64 STRINGS. For a 4 MB original that means base64-encoding the whole
  /// blob to build the isolate request and decoding it again inside: +33 %
  /// allocation and two extra full passes over the bytes, per view, to move
  /// data that was already in the right shape.
  ///
  /// Small payloads stay inline. `compute` spawns a fresh isolate per call —
  /// tens of milliseconds on an IN2015 plus two copies — while XChaCha20 over
  /// a 120 KB cover is well under a millisecond. Prefetching two dozen covers
  /// as two dozen isolate hops would be slower than simply doing them here.
  /// [encryptBytesOffThread] already draws the line in the same place.
  static Future<Uint8List> decryptBytesOffThread(
    Uint8List packed, {
    String? associatedData,
  }) async {
    if (packed.length < _nonceLength + _macLength) {
      throw ArgumentError('packed blob is ${packed.length} bytes, too short to '
          'carry a nonce and a MAC');
    }
    final keyBytes = await exportSharedKeyBytes();
    if (packed.length < 256 * 1024) {
      return _decryptPacked(_DecryptRequest(packed, associatedData, keyBytes));
    }
    return compute(
      _decryptPacked,
      _DecryptRequest(packed, associatedData, keyBytes),
    );
  }

  static Future<String> decryptString(
    EncryptedPayload payload, {
    String? associatedData,
  }) async =>
      utf8.decode(await decryptBytes(payload, associatedData: associatedData));

  static Future<Uint8List> decryptBytes(
    EncryptedPayload payload, {
    String? associatedData,
  }) async {
    final nonce = base64Decode(payload.nonceB64);
    final mac = base64Decode(payload.macB64);
    final ct = base64Decode(payload.ciphertextB64);

    // Legacy / plaintext-mode row: the bytes are the cleartext.
    if (_isLegacy(nonce, mac)) return Uint8List.fromList(ct);

    final key = _sharedKey;
    if (key == null) {
      throw StateError('encrypted row but no couple key — partner key missing');
    }
    final clear = await _aead.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
      aad: associatedData == null ? const <int>[] : utf8.encode(associatedData),
    );
    return Uint8List.fromList(clear);
  }

  /// Deterministic, keyless tag hash so Fantasy-Jar tag matching still works
  /// (both partners compute the same value). FNV-1a — no secret required.
  static Future<String> hmacTag(String tag) async {
    final norm = utf8.encode(tag.toLowerCase().trim());
    var h = 0x811c9dc5;
    for (final b in norm) {
      h ^= b;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return 'tag_${h.toRadixString(16)}';
  }
}

/// XChaCha20-Poly1305 always produces a 24-byte nonce and a 16-byte Poly1305 MAC.
const int _nonceLength = 24;
const int _macLength = 16;

/// Container for one encrypted value: ciphertext, its nonce, and its MAC, each
/// base64. A legacy/plaintext-mode value has an all-zero nonce and MAC.
class EncryptedPayload {
  const EncryptedPayload({
    required this.ciphertextB64,
    required this.nonceB64,
    required this.macB64,
  });

  final String ciphertextB64;
  final String nonceB64;
  final String macB64;
}


/// Arguments for [_decryptPacked]. Top-level for the same reason as
/// [_EncryptRequest].
class _DecryptRequest {
  const _DecryptRequest(this.packed, this.ad, this.keyBytes);

  final Uint8List packed;
  final String? ad;
  final List<int>? keyBytes;
}

/// Splits `nonce || mac || ciphertext` and opens it.
///
/// Runs either inline or in an isolate, so it must not touch [CryptoCore]'s
/// state — the key arrives as raw bytes.
Future<Uint8List> _decryptPacked(_DecryptRequest r) async {
  final nonce = Uint8List.sublistView(r.packed, 0, _nonceLength);
  final mac = Uint8List.sublistView(r.packed, _nonceLength, _nonceLength + _macLength);
  final ct = Uint8List.sublistView(r.packed, _nonceLength + _macLength);

  // The legacy / plaintext-mode shape, preserved on the read path forever:
  // an all-zero nonce and MAC means the bytes are the cleartext. One
  // production row is in exactly this state.
  if (nonce.every((b) => b == 0) && mac.every((b) => b == 0)) {
    return Uint8List.fromList(ct);
  }
  if (r.keyBytes == null) {
    throw StateError('encrypted media but no couple key — partner key missing');
  }
  final clear = await Xchacha20.poly1305Aead().decrypt(
    SecretBox(ct, nonce: nonce, mac: Mac(mac)),
    secretKey: SecretKey(r.keyBytes!),
    aad: r.ad == null ? const <int>[] : utf8.encode(r.ad!),
  );
  return Uint8List.fromList(clear);
}

/// Arguments for [_isolateEncrypt]. Top-level because `compute` sends the
/// callback by reference and it must not close over anything.
class _EncryptRequest {
  const _EncryptRequest(this.bytes, this.ad, this.keyBytes);

  final Uint8List bytes;
  final String? ad;
  final List<int> keyBytes;
}

/// Encrypt on a background isolate.
///
/// The vault encrypts the ORIGINAL media — up to 100MB — and did it here on the
/// main isolate. AES/XChaCha over 100MB plus a base64 encode of the result is
/// seconds of solid CPU on the UI thread, which is why the upload spinner did
/// not merely take a long time: it stopped animating entirely, because the
/// thread that would have animated it was busy. Mirrors the decrypt isolate the
/// vault cache already uses.
Future<EncryptedPayload> _isolateEncrypt(_EncryptRequest r) async {
  final box = await Xchacha20.poly1305Aead().encrypt(
    r.bytes,
    secretKey: SecretKey(r.keyBytes),
    aad: r.ad == null ? const <int>[] : utf8.encode(r.ad!),
  );
  return EncryptedPayload(
    ciphertextB64: base64Encode(box.cipherText),
    nonceB64: base64Encode(box.nonce),
    macB64: base64Encode(box.mac.bytes),
  );
}
