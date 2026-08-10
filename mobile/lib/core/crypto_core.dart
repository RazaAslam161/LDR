import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
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

  static Future<SimpleKeyPair> _keyPair() async {
    if (_myKeyPair != null) return _myKeyPair!;
    final stored = await _storage.read(key: _privKeyStoreKey);
    if (stored != null) {
      _myKeyPair = await _x25519.newKeyPairFromSeed(base64Decode(stored));
    } else {
      final kp = await _x25519.newKeyPair();
      final data = await kp.extract();
      await _storage.write(
          key: _privKeyStoreKey, value: base64Encode(data.bytes),);
      _myKeyPair = kp;
    }
    return _myKeyPair!;
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
    if (partnerPublicKeyB64 == legacyPublicKey) {
      _sharedKey = null;
      return;
    }
    Uint8List partnerPub;
    try {
      partnerPub = base64Decode(partnerPublicKeyB64);
    } catch (_) {
      _sharedKey = null;
      return;
    }
    if (partnerPub.length != 32) {
      _sharedKey = null;
      return;
    }

    final shared = await _x25519.sharedSecretKey(
      keyPair: await _keyPair(),
      remotePublicKey: SimplePublicKey(partnerPub, type: KeyPairType.x25519),
    );
    _sharedKey = await _hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode('miles-closer-v1'),
    );
  }

  static void clearCache() => _sharedKey = null;

  static bool _isLegacy(Uint8List nonce, Uint8List mac) =>
      nonce.every((b) => b == 0) && mac.every((b) => b == 0);

  static Future<EncryptedPayload> encryptString(
    String plaintext, {
    String? associatedData,
  }) =>
      encryptBytes(utf8.encode(plaintext), associatedData: associatedData);

  static Future<EncryptedPayload> encryptBytes(
    List<int> bytes, {
    String? associatedData,
  }) async {
    final key = _sharedKey;
    if (key == null) {
      // Plaintext mode: identical shape to the pre-2026-08 rows, so the read
      // path treats it as legacy. No worse than before; upgrades itself the
      // moment the partner publishes a real key.
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
