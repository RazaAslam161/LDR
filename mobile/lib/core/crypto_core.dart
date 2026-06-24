import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// End-to-end encryption core for the Closer intimacy module.
///
/// Design (see docs/INTIMACY_LAYER.md §5):
///   - X25519 keypair per device, generated on first enable
///   - Couple-shared symmetric key = X25519(my_private, their_public)
///   - XChaCha20-Poly1305 for per-item encryption (random 24-byte nonce)
///   - Private keys in Android Keystore via flutter_secure_storage
///   - The founder (us) cannot read any of this — we have no keys.
class CryptoCore {
  CryptoCore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _privKeyKey = 'miles_closer_private_key';
  static const _pubKeyKey = 'miles_closer_public_key';

  static final _x25519 = X25519();
  static final _chacha = Xchacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// The couple-derived symmetric secret key. Cached after first derivation.
  static SecretKey? _sharedSecret;

  // ─── Keypair management ──────────────────────────────────────

  /// Returns my keypair, generating one on first call.
  static Future<KeyPair> _getOrCreateKeypair() async {
    final priv = await _storage.read(key: _privKeyKey);
    final pub = await _storage.read(key: _pubKeyKey);

    if (priv != null && pub != null) {
      final privBytes = Uint8List.fromList(base64Decode(priv));
      final pubBytes = Uint8List.fromList(base64Decode(pub));
      return SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    }

    // Generate fresh
    final pair = await _x25519.newKeyPair();
    final privData = await pair.extractPrivateKeyBytes();
    final pubKey = await pair.extractPublicKey();
    final pubData = (pubKey as SimplePublicKey).bytes;

    await _storage.write(key: _privKeyKey, value: base64Encode(privData));
    await _storage.write(key: _pubKeyKey, value: base64Encode(pubData));

    return pair;
  }

  /// Returns my public key as base64 — safe to publish to the partner_keys
  /// table. Contains nothing secret.
  static Future<String> getMyPublicKeyB64() async {
    final pair = await _getOrCreateKeypair();
    final pub = await pair.extractPublicKey();
    // Cast to SimplePublicKey so we can access .bytes
    final simplePub = pub as SimplePublicKey;
    return base64Encode(simplePub.bytes);
  }

  // ─── Shared key derivation ───────────────────────────────────

  /// Derives and caches the couple-shared symmetric key from my private key
  /// and my partner's public key. Call after fetching partner's public key.
  static Future<SecretKey> deriveSharedKey({
    required String partnerPublicKeyB64,
  }) async {
    if (_sharedSecret != null) return _sharedSecret!;

    final myPair = await _getOrCreateKeypair();
    final theirPubBytes =
        Uint8List.fromList(base64Decode(partnerPublicKeyB64));
    final theirPubKey =
        SimplePublicKey(theirPubBytes, type: KeyPairType.x25519);

    // Run X25519 ECDH
    final shared = await _x25519.sharedSecretKey(
      keyPair: myPair,
      remotePublicKey: theirPubKey,
    );

    // Run through HKDF to get a clean 32-byte key for XChaCha20
    final rawBytes = await shared.extractBytes();
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey(rawBytes),
      info: 'miles-closer-v1'.codeUnits,
      nonce: const <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
    );

    _sharedSecret = derived;
    return derived;
  }

  /// Clears the cached shared secret (e.g. on couple change / sign out).
  static void clearCache() {
    _sharedSecret = null;
  }

  // ─── Encrypt / decrypt ──────────────────────────────────────

  /// Encrypts plaintext + returns (ciphertext, nonce) as base64 strings.
  static Future<EncryptedPayload> encryptString(
    String plaintext, {
    String? associatedData,
  }) async {
    final key = _sharedSecret;
    if (key == null) {
      throw StateError('Shared key not derived. Call deriveSharedKey first.');
    }

    final secretBox = await _chacha.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      aad: associatedData != null ? utf8.encode(associatedData) : <int>[],
    );

    return EncryptedPayload(
      ciphertextB64: base64Encode(secretBox.cipherText),
      nonceB64: base64Encode(secretBox.nonce),
      macB64: base64Encode((await secretBox.mac).bytes),
    );
  }

  /// Decrypts an [EncryptedPayload] back to plaintext.
  static Future<String> decryptString(
    EncryptedPayload payload, {
    String? associatedData,
  }) async {
    final key = _sharedSecret;
    if (key == null) {
      throw StateError('Shared key not derived.');
    }

    final secretBox = SecretBox(
      base64Decode(payload.ciphertextB64),
      nonce: base64Decode(payload.nonceB64),
      mac: Mac(base64Decode(payload.macB64)),
    );

    final plainBytes = await _chacha.decrypt(
      secretBox,
      secretKey: key,
      aad: associatedData != null ? utf8.encode(associatedData) : <int>[],
    );
    return utf8.decode(plainBytes);
  }

  /// Encrypts raw bytes (for photos / voice). Returns the same payload shape.
  static Future<EncryptedPayload> encryptBytes(
    List<int> bytes, {
    String? associatedData,
  }) async {
    final key = _sharedSecret;
    if (key == null) {
      throw StateError('Shared key not derived.');
    }
    final secretBox = await _chacha.encrypt(
      bytes,
      secretKey: key,
      aad: associatedData != null ? utf8.encode(associatedData) : <int>[],
    );
    return EncryptedPayload(
      ciphertextB64: base64Encode(secretBox.cipherText),
      nonceB64: base64Encode(secretBox.nonce),
      macB64: base64Encode((await secretBox.mac).bytes),
    );
  }

  /// Decrypts raw bytes back to a [Uint8List].
  static Future<Uint8List> decryptBytes(
    EncryptedPayload payload, {
    String? associatedData,
  }) async {
    final key = _sharedSecret;
    if (key == null) {
      throw StateError('Shared key not derived.');
    }
    final secretBox = SecretBox(
      base64Decode(payload.ciphertextB64),
      nonce: base64Decode(payload.nonceB64),
      mac: Mac(base64Decode(payload.macB64)),
    );
    final plain = await _chacha.decrypt(
      secretBox,
      secretKey: key,
      aad: associatedData != null ? utf8.encode(associatedData) : <int>[],
    );
    return Uint8List.fromList(plain);
  }

  // ─── HMAC for tag-hashing (Fantasy Jar) ─────────────────────

  /// HMAC-SHA256 keyed with the couple-shared secret. Used to hash
  /// fantasy-jar tags without revealing them in plaintext.
  static Future<String> hmacTag(String tag) async {
    final key = _sharedSecret;
    if (key == null) throw StateError('Shared key not derived.');
    final rawKey = await key.extractBytes();
    final hmac = Hmac.sha256();
    final mac = await hmac.calculateMac(
      utf8.encode(tag.toLowerCase().trim()),
      secretKey: SecretKey(rawKey),
    );
    return base64Encode(mac.bytes);
  }
}

/// Convenience container for an encrypted blob + its nonce + MAC.
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
