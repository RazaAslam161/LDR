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
/// Top-level so it can cross an isolate boundary via [compute].
Future<List<int>> _argon2idDerive(
  ({String password, Uint8List salt}) args,
) async {
  final key = await Argon2id(
    memory: KeyEscrow._argonMemoryKb,
    iterations: KeyEscrow._argonIterations,
    parallelism: KeyEscrow._argonParallelism,
    hashLength: 32,
  ).deriveKey(
    secretKey: SecretKey(utf8.encode(args.password)),
    nonce: args.salt,
  );
  return key.extractBytes();
}

class KeyEscrow {
  KeyEscrow._();

  static final _aead = Xchacha20.poly1305Aead();

  /// OWASP's baseline Argon2id configuration. Measured at ~0.5s on the oldest
  /// handset, which is the ceiling worth paying at sign-in.
  static const kdfArgon2id = 'argon2id';
  static const _argonMemoryKb = 19456;
  static const _argonIterations = 2;
  static const _argonParallelism = 1;

  static Map<String, dynamic> get _argonParams => const {
        'm': _argonMemoryKb,
        't': _argonIterations,
        'p': _argonParallelism,
      };

  /// Derive the wrapping key. Never leaves the device.
  ///
  /// Argon2id is memory-hard on purpose: the sealed seed sits in a table a
  /// backup dump or a leaked service-role key would expose, and the only thing
  /// standing between that blob and the couple's entire history is the user's
  /// password. The original HKDF derivation was two HMAC-SHA256 operations per
  /// guess, which a GPU does by the billion — it hid the password from the
  /// server while leaving the key it protects trivially recoverable offline.
  ///
  /// Run off the UI isolate; half a second of memory-hard work on the platform
  /// thread is a visible freeze during sign-in.
  static Future<SecretKey> _wrapKey(
    String password,
    Uint8List salt, {
    required String kdf,
  }) async {
    if (kdf != kdfArgon2id) return _legacyWrapKey(password, salt);
    final bytes = await compute(
      _argon2idDerive,
      (password: password, salt: salt),
    );
    return SecretKey(bytes);
  }

  /// Rows sealed before the Argon2id migration. Kept only so [restore] can open
  /// one and immediately re-wrap it; nothing writes this format any more.
  static Future<SecretKey> _legacyWrapKey(String password, Uint8List salt) =>
      Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
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
      final key = await _wrapKey(password, salt, kdf: kdfArgon2id);
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
        'kdf': kdfArgon2id,
        'kdf_params': _argonParams,
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
          .select('wrapped_seed, salt, nonce, kdf')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return false;

      final sealed = byteaToBytes(row['wrapped_seed']);
      final salt = byteaToBytes(row['salt']);
      final nonce = byteaToBytes(row['nonce']);
      if (sealed.length <= 16) return false;

      // A row written before the Argon2id migration has no discriminator.
      final kdf = (row['kdf'] as String?) ?? 'hkdf-sha256';
      final key = await _wrapKey(password, salt, kdf: kdf);
      final cipher = sealed.sublist(0, sealed.length - 16);
      final mac = sealed.sublist(sealed.length - 16);

      final seed = await _aead.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
      await CryptoCore.adoptPrivateSeed(Uint8List.fromList(seed));

      // Opening a legacy row proves the password, which is the only moment the
      // material needed to re-seal it exists. Upgrade in place rather than
      // leaving a crackable blob behind for the life of the account.
      if (kdf != kdfArgon2id) await backup(password);
      return true;
    } catch (e) {
      // A wrong password lands here as a MAC failure, which is the expected
      // outcome rather than an error worth surfacing.
      debugPrint('[escrow] restore failed: ${e.runtimeType}');
      return false;
    }
  }
}
