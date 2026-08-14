import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// Lets a reinstall keep the couple's encrypted history.
///
/// The X25519 private key lives in FlutterSecureStorage, and Android wipes that
/// on uninstall. So every reinstall minted a fresh keypair, changed the ECDH
/// shared secret, and left every previously-encrypted row permanently
/// unreadable — the SecretBoxAuthenticationError on memory threads, fantasy jar
/// and the vault tiles. Nothing was corrupted. The key that opened it was
/// thrown away, by the operating system, on purpose.
///
/// The seed is sealed under a key derived from the user's own password and the
/// sealed form is kept server-side. The server holds ciphertext and a salt; it
/// never receives the password, so it can never derive the wrapping key. That
/// keeps the end-to-end property intact while making the history survive a
/// reinstall.
///
/// The cost, stated plainly: a forgotten password means the escrow cannot be
/// opened either. That is the same trade every honest end-to-end system makes,
/// and it is better than the current behaviour, which loses everything on a
/// reinstall the user did not even know was destructive.
class KeyEscrow {
  KeyEscrow._();

  static final _aead = Xchacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Derive the wrapping key. Never leaves the device.
  static Future<SecretKey> _wrapKey(String password, Uint8List salt) =>
      _hkdf.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
        info: utf8.encode('miles_key_escrow_v1'),
      );

  /// True when this account has no escrow row and would lose everything on a
  /// reinstall.
  ///
  /// Exists because backup can only happen where the password does — sign-in
  /// and sign-up. Every user already signed in when this shipped has no escrow
  /// and no reason to sign out, so the app has to notice and ask them once.
  /// Telling a fleet to sign out and back in is not a migration strategy.
  static Future<bool> isMissing() async {
    try {
      final uid = SupabaseService.currentUserId;
      if (uid == null) return false;
      final row = await SupabaseService.client
          .from('key_escrow')
          .select('user_id')
          .eq('user_id', uid)
          .maybeSingle();
      return row == null;
    } catch (_) {
      // Offline is not "missing". Prompting on a failed lookup would nag every
      // user every time their connection dropped.
      return false;
    }
  }

  /// Seal this device's seed under [password] and store it.
  ///
  /// Called after a successful sign-in, when the password is in hand and the
  /// keypair is known. Idempotent: re-wrapping with the same password simply
  /// replaces the row, which is also what makes a password change recoverable
  /// as long as it happens while the old key is still on the device.
  static Future<void> backup(String password) async {
    try {
      final uid = SupabaseService.currentUserId;
      final seed = await CryptoCore.exportPrivateSeed();
      if (uid == null || seed == null) return;

      final rnd = Random.secure();
      final salt =
          Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
      final key = await _wrapKey(password, salt);
      final box = await _aead.encrypt(
        seed,
        secretKey: key,
        nonce: _aead.newNonce(),
      );
      // MAC appended to the ciphertext, same packing the rest of the app uses.
      final sealed = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);

      await SupabaseService.client.from('key_escrow').upsert({
        'user_id': uid,
        'wrapped_seed': bytesToBytea(sealed),
        'salt': bytesToBytea(salt),
        'nonce': bytesToBytea(Uint8List.fromList(box.nonce)),
      });
    } catch (e) {
      // Best effort. Failing to back the key up must never fail a sign-in —
      // the user simply keeps the behaviour they have today.
      debugPrint('[escrow] backup skipped: ${e.runtimeType}');
    }
  }

  /// Recover the seed for this account and install it locally.
  ///
  /// Returns true only when a seed was found, opened, and adopted. False means
  /// there is nothing to recover or the password does not open it, and the
  /// caller should carry on with a freshly generated key.
  static Future<bool> restore(String password) async {
    try {
      final uid = SupabaseService.currentUserId;
      if (uid == null) return false;

      final row = await SupabaseService.client
          .from('key_escrow')
          .select('wrapped_seed, salt, nonce')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return false;

      final sealed = byteaToBytes(row['wrapped_seed']);
      final salt = byteaToBytes(row['salt']);
      final nonce = byteaToBytes(row['nonce']);
      if (sealed.length <= 16) return false;

      final key = await _wrapKey(password, salt);
      final cipher = sealed.sublist(0, sealed.length - 16);
      final mac = sealed.sublist(sealed.length - 16);

      final seed = await _aead.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
      await CryptoCore.adoptPrivateSeed(Uint8List.fromList(seed));
      return true;
    } catch (e) {
      // A wrong password lands here as a MAC failure, which is the expected
      // outcome rather than an error worth surfacing.
      debugPrint('[escrow] restore failed: ${e.runtimeType}');
      return false;
    }
  }
}
