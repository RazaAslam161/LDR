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
/// The seed is sealed under a key derived from the user's own password, and the
/// sealed form is kept server-side. The server holds ciphertext, a salt and a
/// nonce, and can derive nothing from those alone.
///
/// What is NOT true — and what this file and the migration both used to claim —
/// is that the server never receives the password. GoTrue receives it in
/// plaintext on every auth request, and the v1 wrap was derived from that exact
/// string, so one logged request was the escrowed seed. The wrap that fixes it
/// has a label of its own ([KeyEscrow._wrapLabel]) and, as of 2026-08-18, is
/// also what gets WRITTEN — see [KeyEscrow.backup] for why the flip had to wait
/// on the version gate. Against somebody who has captured the password
/// neither form buys anything: escrow is only ever as strong as the password
/// and the auth endpoint.
///
/// The cost, stated plainly: a forgotten password means the escrow cannot be
/// opened either. That is the same trade every honest end-to-end system makes,
/// and it is better than the current behaviour, which loses everything on a
/// reinstall the user did not even know was destructive.
/// Top-level so it can cross an isolate boundary via [compute]. Shared with
/// PartnerRewrap, which commits to six digits the same memory-hard way rather
/// than with a hash a row-reader could exhaust.
Future<List<int>> argon2idDerive(
  ({String secret, Uint8List salt}) args,
) =>
    argon2idDeriveWith(
      (
        secret: args.secret,
        salt: args.salt,
        m: KeyEscrow._argonMemoryKb,
        t: KeyEscrow._argonIterations,
        p: KeyEscrow._argonParallelism,
      ),
    );

/// The same derivation at the parameters a stored row was sealed with.
///
/// Every escrow row carries its own m/t/p. Deriving with today's constants
/// instead of the row's makes every existing row underivable the day those
/// constants are hardened — the same silent, permanent loss escrow exists to
/// prevent, arriving on a fleet with no update channel.
Future<List<int>> argon2idDeriveWith(
  ({String secret, Uint8List salt, int m, int t, int p}) args,
) async {
  final key = await Argon2id(
    memory: args.m,
    iterations: args.t,
    parallelism: args.p,
    hashLength: 32,
  ).deriveKey(
    secretKey: SecretKey(utf8.encode(args.secret)),
    nonce: args.salt,
  );
  return key.extractBytes();
}

class KeyEscrow {
  KeyEscrow._();

  static final _aead = Xchacha20.poly1305Aead();

  /// OWASP's baseline Argon2id configuration. Measured at ~0.5s on the oldest
  /// handset, which is the ceiling worth paying at sign-in.
  static const _argonMemoryKb = 19456;
  static const _argonIterations = 2;
  static const _argonParallelism = 1;

  /// Argon2id over the password itself. Nothing writes it since 2026-08-18;
  /// kept so [restore] can open every row sealed before the flip.
  static const kdfArgon2id = 'argon2id';

  /// The same Argon2id over [_escrowSecret] instead of the string GoTrue is
  /// sent. Readable since build 27; what [backup] writes since 2026-08-18,
  /// when the version gate guaranteed no permitted build could fail to open
  /// it — see [backup].
  static const kdfArgon2idV2 = 'argon2id-v2';

  /// The column default, and what a row from before the Argon2id migration
  /// carries — those predate the discriminator entirely.
  static const _kdfLegacyHkdf = 'hkdf-sha256';

  static Map<String, dynamic> get _argonParams => const {
        'm': _argonMemoryKb,
        't': _argonIterations,
        'p': _argonParallelism,
      };

  /// Domain separation, and the whole of what it is worth.
  ///
  /// The password goes to GoTrue in plaintext on every auth request. Deriving
  /// the wrap from that same string meant the two secrets were one secret, so
  /// an endpoint that logs its request body holds the key to every escrowed
  /// seed. One HMAC under a label nothing else uses makes them different bytes.
  /// It does not make them independent — anyone holding the password can run
  /// this line too — and nothing available on a phone whose user may be
  /// standing in front of a new one can.
  static const _wrapLabel = 'miles/key-escrow/wrap/v2';

  static Future<String> _escrowSecret(String password) async {
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(password),
      secretKey: SecretKey(utf8.encode(_wrapLabel)),
    );
    return base64Encode(mac.bytes);
  }

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
    Map<String, dynamic>? params,
  }) async {
    // Anything this build does not recognise is a row from before the Argon2id
    // migration, which carried no discriminator at all.
    if (kdf != kdfArgon2id && kdf != kdfArgon2idV2) {
      return _legacyWrapKey(password, salt);
    }
    final bytes = await compute(
      argon2idDeriveWith,
      (
        secret: kdf == kdfArgon2id ? password : await _escrowSecret(password),
        salt: salt,
        m: _param(params, 'm', _argonMemoryKb),
        t: _param(params, 't', _argonIterations),
        p: _param(params, 'p', _argonParallelism),
      ),
    );
    return SecretKey(bytes);
  }

  static int _param(Map<String, dynamic>? params, String key, int fallback) =>
      (params?[key] as num?)?.toInt() ?? fallback;

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

  /// Seal this device's seed under [password] and store it. True when a row was
  /// actually written.
  ///
  /// Called after a successful sign-in, when the password is in hand and the
  /// keypair is known. Idempotent: re-wrapping with the same password simply
  /// replaces the row, which is also what makes a password change recoverable
  /// as long as it happens while the old key is still on the device.
  ///
  /// The return value is the point. Every no-op here used to be indistinguish-
  /// able from a success, so a reset on a phone with no seed reported "done"
  /// over a row still sealed under the forgotten password.
  static Future<bool> backup(String password) async {
    try {
      final uid = SupabaseService.currentUserId;
      final seed = await CryptoCore.exportPrivateSeed();
      if (uid == null || seed == null) return false;
      // A device in recovery holds a stand-in key that opens nothing the couple
      // wrote. Sealing it over the row that still holds the real one is the
      // difference between a recovery that is merely pending and a history that
      // is gone — but where there is no row at all there is nothing to lose,
      // and content written from here on deserves somewhere to be recovered
      // from. isMissing() reports false when it cannot reach the server, which
      // lands on the refusing side.
      if (await CryptoCore.isKeyless() && !await isMissing()) return false;

      final rnd = Random.secure();
      final salt =
          Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
      // Sealed as v2 since 2026-08-18. The write stayed on the old format for
      // as long as build 26 was permitted: that build hands anything that is
      // not exactly `argon2id` to the HKDF derivation, so a v2 row fails its
      // MAC there, restore returns false, and the next sign-in seals the
      // stand-in key minted on the first Closer screen over the only copy of
      // the real one. The flip was gated on app_release.min_build reaching 28;
      // production has sat at 42 — every build the gate admits opens v2 — so
      // writing v1 kept the wrap and the sign-in password one secret for
      // nobody's benefit. [_wrapKey] goes on opening v1 rows, and each one
      // re-seals as v2 the next time its owner's sign-in lands here.
      final key = await _wrapKey(password, salt, kdf: kdfArgon2idV2);
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
        'kdf': kdfArgon2idV2,
        'kdf_params': _argonParams,
      });
      return true;
    } catch (e) {
      // Best effort. Failing to back the key up must never fail a sign-in —
      // the user simply keeps the behaviour they have today. The one caller
      // that asked the user for a password reports it instead of pretending.
      debugPrint('[escrow] backup skipped: ${e.runtimeType}');
      return false;
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

      // Never over a live seed. After a rewrap ceremony THIS device holds the
      // newest key while the row still holds the one it replaced, so adopting
      // from the row reverts the seed and leaves everything written since in a
      // key neither phone has. The caller re-seals instead, which is what makes
      // the row converge on the newest key rather than the oldest. A device
      // that has declared itself keyless is the exception: whatever seed it
      // holds was minted as a stand-in, and is exactly what needs replacing.
      if (await CryptoCore.hasSeed() && !await CryptoCore.isKeyless()) {
        return false;
      }

      final row = await SupabaseService.client
          .from('key_escrow')
          .select('wrapped_seed, salt, nonce, kdf, kdf_params')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return false;

      final sealed = byteaToBytes(row['wrapped_seed']);
      final salt = byteaToBytes(row['salt']);
      final nonce = byteaToBytes(row['nonce']);
      if (sealed.length <= 16) return false;

      // A row written before the Argon2id migration has no discriminator, and
      // every row carries the parameters it was actually sealed at — reading
      // them from the row is what keeps it openable after the constants above
      // are ever hardened.
      final kdf = (row['kdf'] as String?) ?? _kdfLegacyHkdf;
      final key = await _wrapKey(
        password,
        salt,
        kdf: kdf,
        params: row['kdf_params'] as Map<String, dynamic>?,
      );
      final cipher = sealed.sublist(0, sealed.length - 16);
      final mac = sealed.sublist(sealed.length - 16);

      final seed = await _aead.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
      );
      await CryptoCore.adoptPrivateSeed(Uint8List.fromList(seed));
      // This device can read the couple's history again, so whatever sent it
      // towards the ceremony is answered — and backup below is allowed again.
      await CryptoCore.clearKeyless();

      // Opening the row proves the password, which is the only moment the
      // material needed to re-seal it exists. Re-wrap anything that is not the
      // current write format: an HKDF row is a crackable blob, and a v1 row's
      // wrap key is the exact string GoTrue receives in plaintext — the
      // exposure the v2 flip exists to close. A v2 row is already current;
      // re-sealing it would spend ~0.5s of Argon2id per restore for nothing.
      // (The comparison flipped with the write format on 2026-08-18: keyed on
      // v1 it skipped upgrading the one format that most needed it and
      // re-sealed every already-current row.)
      if (kdf != kdfArgon2idV2) await backup(password);
      return true;
    } catch (e) {
      // A wrong password lands here as a MAC failure, which is the expected
      // outcome rather than an error worth surfacing.
      debugPrint('[escrow] restore failed: ${e.runtimeType}');
      return false;
    }
  }
}
