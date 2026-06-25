import 'dart:convert';
import 'dart:typed_data';

/// E2EE REMOVED (2026-06-25, at the owner's request).
///
/// For this private, owner-controlled, two-person app the Closer module no
/// longer encrypts data — it stores plaintext (base64) so the features are
/// reliable: no X25519 key exchange, no shared-key derivation, no decrypt
/// failures. Row-Level Security still scopes every row to the couple, so the
/// data is just as private between the two of them.
///
/// The original public API is kept intact so the repositories are unchanged;
/// `encrypt*`/`decrypt*` are now identity pass-throughs.
class CryptoCore {
  CryptoCore._();

  /// No-op — no key is needed anymore. Kept so existing call sites compile.
  static Future<void> deriveSharedKey({
    required String partnerPublicKeyB64,
  }) async {}

  static void clearCache() {}

  /// Kept for the publish-key call site; returns a stable placeholder.
  static Future<String> getMyPublicKeyB64() async => 'plaintext-v1';

  static Future<EncryptedPayload> encryptString(
    String plaintext, {
    String? associatedData,
  }) async =>
      EncryptedPayload(
        ciphertextB64: base64Encode(utf8.encode(plaintext)),
        nonceB64: base64Encode(Uint8List(24)),
        macB64: base64Encode(Uint8List(16)),
      );

  static Future<String> decryptString(
    EncryptedPayload payload, {
    String? associatedData,
  }) async =>
      utf8.decode(base64Decode(payload.ciphertextB64));

  static Future<EncryptedPayload> encryptBytes(
    List<int> bytes, {
    String? associatedData,
  }) async =>
      EncryptedPayload(
        ciphertextB64: base64Encode(bytes),
        nonceB64: base64Encode(Uint8List(24)),
        macB64: base64Encode(Uint8List(16)),
      );

  static Future<Uint8List> decryptBytes(
    EncryptedPayload payload, {
    String? associatedData,
  }) async =>
      Uint8List.fromList(base64Decode(payload.ciphertextB64));

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

/// Container kept for compatibility — now just holds base64 plaintext.
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
