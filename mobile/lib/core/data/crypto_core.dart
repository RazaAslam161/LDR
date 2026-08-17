import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:miles/core/services/server_clock.dart';

/// Couple-shared authenticated encryption for the Closer module.
///
/// History: real E2EE was stripped in 2026-06 back when this was a private
/// two-person app, and encrypt/decrypt became base64 pass-throughs. Real AEAD
/// came back "opportunistically" — plaintext-mode writes and a zero-MAC read
/// branch kept mixed couples working during the rollout. That era ENDED on
/// 2026-08-18: every shipped build refuses the no-key sentinel before deriving,
/// the 2026-08-16 wipe left zero plaintext-shaped rows in any E2EE table
/// (scanned live), and the read branch had become a pure forgery door — a
/// zero-MAC row minted by anything with database write access rendered as
/// authentically the partner's. Both halves are gone: [encryptBytes] refuses
/// without a derived key, and [decryptBytes] verifies every row or fails.
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

  /// Couple keys this device has retired but can still read with, newest first,
  /// as `base64(k0 || k1 || …)`. Scoped per account exactly like the seed: a
  /// device-wide ring would hand the next account keys that open the previous
  /// one's history.
  static const _ringStoreKey = 'miles_key_ring_v1';
  static String get _ringKey =>
      _accountId == null ? _ringStoreKey : '${_ringStoreKey}_$_accountId';

  /// Set while a rewrap is in flight, and the reason it has to outlive the
  /// process.
  ///
  /// Publishing this device's new public key rotates the couple key on BOTH
  /// phones. Do it before the old keys are in hand and the partner seals a key
  /// that opens nothing, while the ceremony reports success — the archive is
  /// gone and both screens say it worked. It also survives a restart because
  /// the seed exists by then, so the sign-in `noKey` gate stops firing and a
  /// device mid-ceremony would otherwise have no way back to its own code.
  static const _holdStoreKey = 'miles_rewrap_hold_v1';
  static String get _holdKey =>
      _accountId == null ? _holdStoreKey : '${_holdStoreKey}_$_accountId';

  /// True while this device is mid-ceremony.
  ///
  /// Lapses with the request rather than needing a "give up" button. A hold
  /// that outlived an abandoned ceremony would lock this device out of Closer
  /// with no way back — a worse trap than the bug it prevents.
  static Future<bool> publicationHeld() async => await heldRequest() != null;

  /// The code is persisted beside the id because it is what the human reads
  /// aloud: a process death mid-ceremony without it leaves a request the
  /// partner can see and this phone can no longer voice. It lives where the
  /// seed lives, and it protects nothing by itself — the commitment on the
  /// server is what it is checked against.
  static Future<void> holdPublication(
    String requestId,
    String code,
    DateTime until,
  ) =>
      _storage.write(
        key: _holdKey,
        value: '$requestId|$code|${until.toUtc().toIso8601String()}',
      );

  /// The ceremony this device is waiting on, so a restart resumes it rather
  /// than stranding the user with a live request and no code to show. Null once
  /// it has lapsed.
  ///
  /// The server's clock, not the device's: lapsing EARLY is the dangerous
  /// direction — a fresh reset with a fast clock would drop the hold the moment
  /// it was written, and the first ensureSharedKey would rotate the couple key
  /// mid-ceremony. ServerClock corrects for skew as soon as any response has
  /// been observed and falls back to the device clock before that.
  static Future<({String id, String code, DateTime until})?>
      heldRequest() async {
    final raw = await _storage.read(key: _holdKey);
    if (raw == null) return null;
    final parts = raw.split('|');
    final until = parts.length == 3 ? DateTime.tryParse(parts[2]) : null;
    if (until == null || ServerClock.now().isAfter(until)) {
      await releasePublication();
      return null;
    }
    return (id: parts[0], code: parts[1], until: until);
  }

  static Future<void> releasePublication() => _storage.delete(key: _holdKey);

  /// Set while this account's history cannot be read on this device.
  ///
  /// Written when a sign-in ends with no seed and no escrow to produce one, or
  /// when a password reset lands on a phone with nothing left to re-seal;
  /// cleared when escrow hands the seed back or a ceremony finishes. Durable
  /// and account-scoped because the ROUTER is what acts on it, and the ordinary
  /// way into the app is a cold start that never passes through sign-in — the
  /// disguise cover backgrounds the app and Android kills the process.
  ///
  /// `1` while the ceremony is still being offered, `deferred` once the user
  /// has tapped past it. Escrow reads both the same way; they differ only in
  /// whether the router keeps sending them back.
  static const _keylessStoreKey = 'miles_key_missing_v1';
  static String get _keylessKey => _accountId == null
      ? _keylessStoreKey
      : '${_keylessStoreKey}_$_accountId';

  /// The router's view of the above, synchronously — a redirect cannot await a
  /// keystore read. Refreshed by [bindAccount], the one place every entry into
  /// an account goes through, sign-in and session restore alike.
  static final ValueNotifier<bool> keyless = ValueNotifier<bool>(false);

  static Future<void> markKeyless() async {
    await _storage.write(key: _keylessKey, value: '1');
    keyless.value = true;
  }

  static Future<void> clearKeyless() async {
    await _storage.delete(key: _keylessKey);
    keyless.value = false;
  }

  /// The stored fact, whatever the user has since said about it.
  ///
  /// [KeyEscrow] asks this one rather than the notifier: a device that cannot
  /// read the couple's history must not seal the stand-in key it mints on the
  /// first Closer screen over the row that still holds the real one.
  static Future<bool> isKeyless() async =>
      await _storage.read(key: _keylessKey) != null;

  /// Stop routing to the ceremony until a sign-in offers it again.
  ///
  /// The fact is kept and only the routing stops: tapping past the offer does
  /// not put the key back on the phone, and escrow goes on refusing to seal the
  /// stand-in one. Without it that screen IS the app — a phone the router
  /// returns to it from every route can reach neither settings nor sign-out.
  static Future<void> deferRecovery() async {
    await _storage.write(key: _keylessKey, value: 'deferred');
    keyless.value = false;
  }

  /// Eight, then the oldest falls off — see [adoptRetiredKeys].
  static const _ringMax = 8;
  static List<SecretKey>? _ring;

  /// The ring index that last opened something, or -1. Content is written in
  /// eras, so consecutive items overwhelmingly share a key.
  static int _ringHit = -1;

  /// The public-key value the old build published for everyone. A partner
  /// still advertising this has no real key, so we cannot encrypt to them yet.
  static const legacyPublicKey = 'plaintext-v1';

  static final _x25519 = X25519();
  static final _aead = Xchacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static SimpleKeyPair? _myKeyPair;

  /// The derived couple key. Null means "not derived" — a state in which
  /// every encrypt and every decrypt REFUSES; there is no plaintext mode for
  /// it to fall into any more.
  static SecretKey? _sharedKey;

  /// The PERSONAL vault's key, derived from this account's own seed alone.
  ///
  /// Deliberately NOT the couple key, which is what the vault used to encrypt
  /// with. That was wrong three separate ways, and only the first was visible:
  ///
  ///   1. It did not work. The couple key is derived on entry to Closer, the
  ///      wish jar or a memory thread, and [bindAccount] nulls it on every cold
  ///      start. Nothing on the vault path ever derived it, so a cold start
  ///      into the vault threw 'no shared key' on the first save — every time,
  ///      for every user. The vault has never once stored a file in production.
  ///
  ///   2. A private vault the partner can read is not private. They hold the
  ///      identical symmetric key on their own phone; owner-only was enforced by
  ///      RLS alone, so any route to the bytes — a dump, a leaked service key, a
  ///      policy regression, the on-disk ciphertext cache — hands them the
  ///      plaintext. This is the one thing the feature promises on its own gate
  ///      screen: "Your partner can never open this."
  ///
  ///   3. It made the owner's private vault depend on the partner's device. The
  ///      partner reinstalls, their public key changes, the couple key changes,
  ///      and the vault stops opening. A breakup orphans it permanently.
  ///
  /// The seed is per-account, present before pairing, restored by [KeyEscrow]
  /// on a new phone, and does not move when the partner does — so the vault
  /// works for a solo user, survives a re-pair, and stays shut to everyone else.
  ///
  /// Changing this derivation strands existing vault media. It costs nothing
  /// today: production holds zero vault rows and zero vault objects, precisely
  /// because of defect 1. That is the whole reason this is safe to change now
  /// and will not be later.
  static SecretKey? _vaultKey;

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
    // Derived from the OUTGOING account's seed. Left standing it would encrypt
    // the new account's vault under the previous one's key — which on a shared
    // handset is the other person's.
    _vaultKey = null;
    _derivedFrom = null;
    // Keyed on the account that just left, and read under the new one's key
    // from here on.
    _ring = null;
    _ringHit = -1;

    if (await _storage.read(key: _seedKey) == null) {
      final owner = await _storage.read(key: _legacySeedOwnerKey);
      final legacy = await _storage.read(key: _privKeyStoreKey);
      if (legacy != null && owner == null) {
        await _storage.write(key: _legacySeedOwnerKey, value: uid);
        await _storage.write(key: _seedKey, value: legacy);
      }
    }
    // Both halves of "this device cannot read what they wrote": the stored fact
    // and a ceremony still in flight. Here rather than at sign-in because a
    // cold start restores a session without ever passing through it — and under
    // the SCOPED keys, which is what a read before binding got wrong.
    keyless.value =
        await _storage.read(key: _keylessKey) == '1' || await publicationHeld();
    _bumpEpoch();
  }

  /// Sign-out. Drops every decrypted byte and every key still held in memory;
  /// the account's sealed seed stays in storage so signing back in works
  /// offline. See [_accountId] for why this does not delete.
  static void forgetAccount() {
    _accountId = null;
    _myKeyPair = null;
    _sharedKey = null;
    _derivedFrom = null;
    _ring = null;
    _ringHit = -1;
    keyless.value = false;
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

  /// True when this account already has a private key on this device.
  ///
  /// False is a reinstall, a cleared keystore or a new phone — the moment
  /// [_keyPair] would silently mint a replacement identity and orphan every
  /// encrypted row the couple wrote. Asked BEFORE that happens, so the loss can
  /// be offered a recovery rather than discovered later as an empty screen.
  static Future<bool> hasSeed() async =>
      await _storage.read(key: _seedKey) != null;

  /// Mint this device's keypair now, if it has none.
  ///
  /// The seed is otherwise created the first time something asks for the
  /// keypair, which is the first Closer screen — long after sign-in, the one
  /// moment the password exists to seal it with. So a new account left sign-in
  /// with nothing to escrow and no second chance until its next sign-in, which
  /// is why production carried two escrow rows against six accounts.
  ///
  /// Only ever call this having established the device is NOT stranded. On a
  /// phone that has lost its key this mints a stand-in, and sealing a stand-in
  /// over the row holding the real one is exactly the loss escrow exists to
  /// prevent.
  static Future<void> ensureSeed() async {
    await _keyPair();
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
  /// perfectly healthy. The ring is deliberately left standing — those keys are
  /// retired rather than derived, so a different seed does not invalidate them.
  static Future<void> adoptPrivateSeed(Uint8List seed) async {
    await _storage.write(key: _seedKey, value: base64Encode(seed));
    _myKeyPair = await _x25519.newKeyPairFromSeed(seed);
    _sharedKey = null;
    // Derived from the seed being replaced. This is the case it matters most:
    // the recovered seed is the one the vault was actually written under, and a
    // stale key here would fail to open the user's own vault on the very phone
    // the escrow restore exists to rescue.
    _vaultKey = null;
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
  /// Fails closed on EVERYTHING that is not a real 32-byte key — the
  /// [legacyPublicKey] sentinel included, since 2026-08-18. Callers refuse
  /// the sentinel themselves first (they own the words on the screen);
  /// reaching the throw here is a caller bug, never a user state.
  static Future<void> deriveSharedKey({
    required String partnerPublicKeyB64,
  }) async {
    // Plaintext mode is OVER (2026-08-18). The sentinel used to switch this
    // class into writing zero-nonce, zero-MAC cleartext for couples where one
    // partner had no key yet; every caller has refused the sentinel before
    // calling here since build 40, the database was wiped 2026-08-16, and a
    // live scan found ZERO plaintext-shaped rows in any E2EE table. Keeping
    // the branch kept a permanent authenticity bypass: anything with write
    // access to the database could mint a zero-MAC row and every device would
    // render it as if the partner wrote it. Reaching this line is therefore a
    // caller bug, and it fails closed like every other bad key.
    if (partnerPublicKeyB64 == legacyPublicKey) {
      _sharedKey = null;
      throw StateError('partner has no key — encryption cannot be derived');
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
    _derivedFrom = null;
    _ring = null;
    _ringHit = -1;
    // Sign-out. Every decrypted byte still held anywhere belongs to the account
    // that just left.
    _bumpEpoch();
  }

  static Future<List<int>?> exportSharedKeyBytes() async {
    if (_sharedKey == null) return null;
    return _sharedKey!.extractBytes();
  }

  /// The personal vault's key — see [_vaultKey] for why it is not the couple key.
  ///
  /// Derives on demand rather than needing a screen to have primed it first.
  /// That is the entire defect being fixed: the couple key had to be derived by
  /// visiting Closer, and the vault never did it, so the vault only worked by
  /// accident. Nothing about opening a private vault should depend on which
  /// other screen the user happened to visit this session.
  ///
  /// Its own HKDF label holds it apart from every other key derived here, so a
  /// vault blob cannot be opened with a couple key and vice versa, even though
  /// both ultimately trace back to the same seed.
  ///
  /// Returns non-null or throws. There is no plaintext fallback: a vault that
  /// writes cleartext when a derivation fails is worse than one that refuses.
  static Future<List<int>> exportVaultKeyBytes() async {
    final cached = _vaultKey;
    if (cached != null) return cached.extractBytes();
    final seed = await (await _keyPair()).extract();
    final key = await _hkdf.deriveKey(
      secretKey: SecretKey(seed.bytes),
      info: utf8.encode('miles-vault-v1'),
    );
    _vaultKey = key;
    return key.extractBytes();
  }

  // ─── The key ring ────────────────────────────────────────────────────────
  // A reinstall changes the derived couple key, so everything written before it
  // stops opening on BOTH phones. The partner's device still holds the old key;
  // PartnerRewrap carries it across and these keep it usable.

  /// A key agreed with [otherPublicKeyB64] for WRAPPING, never for content.
  ///
  /// Its own HKDF label is what holds it apart from the couple key. Wrapping
  /// under the content key would mean one opened wrap hands over everything the
  /// key was protecting.
  static Future<SecretKey> rewrapKey(String otherPublicKeyB64) async {
    final pub = base64Decode(otherPublicKeyB64);
    if (pub.length != 32) {
      throw StateError('rewrap key is ${pub.length} bytes, expected 32');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: await _keyPair(),
      remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode('miles-rewrap-v1'),
    );
  }

  /// Every key this device can decrypt with, newest first: the derived couple
  /// key, then the ring. Empty when nothing is derived — there is then nothing
  /// worth handing to a partner.
  static Future<List<List<int>>> exportKeyChainBytes() async {
    final key = _sharedKey;
    if (key == null) return const [];
    final current = await key.extractBytes();
    final chain = [current];
    // After this device has ANSWERED a ceremony its own ring already holds the
    // derived key, so a naive concat ships it twice — and a duplicate slot in a
    // fixed eight is a real era pushed off the far end with nothing to show.
    for (final k in await _ringBytes()) {
      if (chain.any((held) => listEquals(held, k))) continue;
      chain.add(k);
    }
    return chain;
  }

  /// Retire [keys], newest first. Returns how many fell off the end of the ring.
  ///
  /// Called on BOTH phones during a rewrap, and it has to be: publishing the new
  /// public key changes what X25519 agrees on for the pair, so the key the
  /// partner is handing over is one IT is also about to stop deriving. Retiring
  /// on the giving side is the whole difference between "the history survives"
  /// and "the history moved to the other phone".
  ///
  /// These only ever widen what opens — the current key is whatever this
  /// device's seed derives, and that is unaffected. A key pushed off the end
  /// takes its era's content with it, on this device, permanently.
  static Future<({int added, int dropped})> adoptRetiredKeys(
    List<List<int>> keys,
  ) async {
    final before = await _ringBytes();
    final merged = <List<int>>[];
    for (final key in [...keys, ...before]) {
      if (key.length != 32) {
        throw ArgumentError('a couple key is 32 bytes, got ${key.length}');
      }
      // A repeated ceremony hands back keys already held. Without this the ring
      // fills with copies of one key and pushes real ones off the end.
      if (merged.any((held) => listEquals(held, key))) continue;
      merged.add(key);
    }
    final kept = merged.take(_ringMax).toList();
    final flat = Uint8List(kept.length * 32);
    for (var i = 0; i < kept.length; i++) {
      flat.setRange(i * 32, (i + 1) * 32, kept[i]);
    }
    await _storage.write(key: _ringKey, value: base64Encode(flat));
    _ring = [for (final k in kept) SecretKey(k)];
    _ringHit = -1;
    // The one bump for this ceremony, and the only place the ring bumps at all.
    // Widening the set of keys that can open a box never changes what an
    // already-decrypted box decrypted TO, so cached plaintext stays correct;
    // what the caches hold from before is failure state, and this drops it.
    _bumpEpoch();
    // `added` is what this ceremony actually delivered BEYOND what this device
    // already derives or held. The current derived key is stored (the giving
    // side retires it on purpose) but never counted: in the one failure this
    // number exists to expose — the partner answered with an already-rotated
    // chain — the arriving key IS the derived key, and counting it would print
    // "your history is back" over a recovery that recovered nothing.
    final cur =
        _sharedKey == null ? null : await _sharedKey!.extractBytes();
    final added = kept
        .where((k) =>
            !(cur != null && listEquals(k, cur)) &&
            !before.any((held) => listEquals(held, k)),)
        .length;
    return (added: added, dropped: merged.length - kept.length);
  }

  static Future<List<SecretKey>> _loadRing() async {
    final cached = _ring;
    if (cached != null) return cached;
    final stored = await _storage.read(key: _ringKey);
    final raw = stored == null ? Uint8List(0) : base64Decode(stored);
    return _ring = [
      for (var i = 0; i + 32 <= raw.length; i += 32)
        SecretKey(raw.sublist(i, i + 32)),
    ];
  }

  static Future<List<List<int>>> _ringBytes() async =>
      Future.wait((await _loadRing()).map((k) => k.extractBytes()));

  static Future<EncryptedPayload> encryptString(
    String plaintext, {
    String? associatedData,
  }) =>
      encryptBytes(utf8.encode(plaintext), associatedData: associatedData);

  /// What an isolate needs to encrypt without touching this class's state.
  ///
  /// A SecretKey cannot cross an isolate boundary, so the raw bytes are
  /// exported once on the caller's side and the isolate rebuilds the key.
  /// [keyOverride] encrypts under a key that is not the couple key — the
  /// personal vault, which derives its own from the owner's seed. With
  /// plaintext mode gone, "no key" throws on every path; the override only
  /// decides WHICH key seals, never whether one does.
  static Future<EncryptedPayload> encryptBytesOffThread(
    Uint8List bytes, {
    String? associatedData,
    List<int>? keyOverride,
  }) async {
    final keyBytes = keyOverride ?? await exportSharedKeyBytes();
    // No key is a refusal, and encryptBytes owns the throw — not worth an
    // isolate spawn to reach it.
    if (keyBytes == null) {
      return encryptBytes(bytes, associatedData: associatedData);
    }
    final request = _EncryptRequest(bytes, associatedData, keyBytes);
    // Small payloads cost more to ship across the boundary than to encrypt.
    // Run the same function inline rather than falling back to encryptBytes,
    // which reads _sharedKey and would silently ignore [keyOverride].
    if (bytes.length < 256 * 1024) {
      return _isolateEncrypt(request);
    }
    return compute(_isolateEncrypt, request);
  }

  static Future<EncryptedPayload> encryptBytes(
    List<int> bytes, {
    String? associatedData,
  }) async {
    final key = _sharedKey;
    if (key == null) {
      // Any state with no derived key — a cleared cache, a failed derivation,
      // a race before pairing — must refuse, never write cleartext. The
      // plaintext-mode escape that used to live here is gone with the mode.
      throw StateError(
        'no shared key — refusing to write unencrypted content',
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
    List<int>? keyOverride,
  }) async {
    if (packed.length < _nonceLength + _macLength) {
      throw ArgumentError('packed blob is ${packed.length} bytes, too short to '
          'carry a nonce and a MAC');
    }
    final keyBytes = keyOverride ?? await exportSharedKeyBytes();
    // With no couple key this is a throw either way — the isolate's own
    // no-key guard fires before any ring key could be tried, so loading the
    // ring here would spend a keystore read on a blob that cannot open. (A
    // couple-key blob that WOULD open under a retired ring key still needs
    // the current key derived first; that is the pre-existing shape of this
    // path, unchanged by plaintext mode's removal.)
    //
    // The ring is retired COUPLE keys. A vault blob was never written under
    // one, so trying them would be a keystore read per tile to attempt keys
    // that cannot match.
    final ring = keyOverride != null || keyBytes == null
        ? const <List<int>>[]
        : await _ringBytes();
    if (packed.length < 256 * 1024) {
      return _decryptPacked(
        _DecryptRequest(packed, associatedData, keyBytes, ring),
      );
    }
    return compute(
      _decryptPacked,
      _DecryptRequest(packed, associatedData, keyBytes, ring),
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

    // No zero-MAC acceptance. The plaintext-mode shape used to pass here
    // verbatim, which handed anything with database write access a permanent
    // forgery primitive: a minted zero-MAC row rendered as authentically the
    // partner's. Zero rows of that shape exist (scanned live 2026-08-18), so
    // it now fails exactly like any other row whose MAC does not verify.

    final key = _sharedKey;
    if (key == null) {
      throw StateError('encrypted row but no couple key — partner key missing');
    }
    final (clear, hit) = await openWithChain(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      key,
      await _loadRing(),
      associatedData == null ? const <int>[] : utf8.encode(associatedData),
      _ringHit,
    );
    _ringHit = hit;
    return clear;
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
/// base64. Every value is a real AEAD box now — the zero-nonce/zero-MAC
/// plaintext shape is refused on read and impossible on write.
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
  const _DecryptRequest(this.packed, this.ad, this.keyBytes, this.ring);

  final Uint8List packed;
  final String? ad;
  final List<int>? keyBytes;
  final List<List<int>> ring;
}

/// Splits `nonce || mac || ciphertext` and opens it.
///
/// Runs either inline or in an isolate, so it must not touch [CryptoCore]'s
/// state — the key arrives as raw bytes.
Future<Uint8List> _decryptPacked(_DecryptRequest r) async {
  final nonce = Uint8List.sublistView(r.packed, 0, _nonceLength);
  final mac = Uint8List.sublistView(r.packed, _nonceLength, _nonceLength + _macLength);
  final ct = Uint8List.sublistView(r.packed, _nonceLength + _macLength);

  // No zero-MAC acceptance here either — this is the same forgery door as
  // decryptBytes', on the media path. See the comment there.
  if (r.keyBytes == null) {
    throw StateError('encrypted media but no couple key — partner key missing');
  }
  final (clear, _) = await openWithChain(
    SecretBox(ct, nonce: nonce, mac: Mac(mac)),
    SecretKey(r.keyBytes!),
    [for (final k in r.ring) SecretKey(k)],
    r.ad == null ? const <int>[] : utf8.encode(r.ad!),
    // No memo survives an isolate boundary. The ring is newest-first, so
    // starting at 0 is the best guess available on this side.
    -1,
  );
  return clear;
}

/// Try [key], then [ring] in [ringOrder]; the first clean open wins, and the
/// index that worked comes back so the caller can try it first next time.
///
/// Trying keys in turn is safe because a wrong one cannot yield plaintext here:
/// XChaCha20-Poly1305 verifies the Poly1305 tag and throws, and a wrong 256-bit
/// key producing a tag that verifies is 2^-128 per attempt. The fallback can
/// only turn a failure into a success, never a success into a different one.
Future<(Uint8List clear, int hit)> openWithChain(
  SecretBox box,
  SecretKey key,
  List<SecretKey> ring,
  List<int> aad,
  int prefer,
) async {
  final aead = Xchacha20.poly1305Aead();
  try {
    return (Uint8List.fromList(await aead.decrypt(box, secretKey: key, aad: aad)), -1);
  } on SecretBoxAuthenticationError {
    for (final i in ringOrder(ring.length, prefer)) {
      try {
        final clear = await aead.decrypt(box, secretKey: ring[i], aad: aad);
        return (Uint8List.fromList(clear), i);
      } on SecretBoxAuthenticationError {
        continue;
      }
    }
    // Exhausted. The ORIGINAL failure is what leaves, because that exact type
    // is what memory_failure.dart classifies as gone rather than transient.
    rethrow;
  }
}

/// [prefer] first when it is a real index, then 0..[n]-1 skipping it.
List<int> ringOrder(int n, int prefer) => [
      if (prefer >= 0 && prefer < n) prefer,
      for (var i = 0; i < n; i++)
        if (i != prefer) i,
    ];

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
