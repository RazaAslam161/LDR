import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/key_escrow.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// One live request: a phone with no key asking the other one for it.
class RewrapRequest {
  const RewrapRequest({
    required this.id,
    required this.newPublicKeyB64,
    required this.codeHash,
    required this.expiresAt,
  });

  factory RewrapRequest.fromRow(Map<String, dynamic> row) => RewrapRequest(
        id: row['id'] as String,
        newPublicKeyB64: row['new_public_key'] as String,
        codeHash: byteaToBytes(row['code_hash']),
        expiresAt: DateTime.parse(row['expires_at'] as String),
      );

  final String id;
  final String newPublicKeyB64;
  final Uint8List codeHash;
  final DateTime expiresAt;
}

/// One byte of version on a format that has nowhere else to put one, shipping
/// to phones with no update channel.
const int _chainVersion = 0x01;
const int _chainSlots = 8;
const int _chainBytes = 2 + _chainSlots * 32;

/// `version(0x01) || n || 8 x 32-byte slot`, zeroed past n — always 258 bytes.
///
/// Fixed length is the point: a blob that grew with the number of keys would
/// tell the server how many times this couple has re-keyed.
Uint8List packChain(List<List<int>> keys) {
  if (keys.isEmpty || keys.length > _chainSlots) {
    throw ArgumentError(
      'a chain carries 1..$_chainSlots keys, got ${keys.length}',
    );
  }
  final out = Uint8List(_chainBytes);
  out[0] = _chainVersion;
  out[1] = keys.length;
  for (var i = 0; i < keys.length; i++) {
    if (keys[i].length != 32) {
      throw ArgumentError('a couple key is 32 bytes, got ${keys[i].length}');
    }
    out.setRange(2 + i * 32, 2 + (i + 1) * 32, keys[i]);
  }
  return out;
}

/// Inverse of [packChain]. Every rejection here is a blob that did not come
/// from a phone running this code, so none of them has a fallback.
List<List<int>> unpackChain(Uint8List clear) {
  if (clear.length != _chainBytes) {
    throw ArgumentError('a chain is $_chainBytes bytes, got ${clear.length}');
  }
  if (clear[0] != _chainVersion) {
    throw ArgumentError('unknown chain version ${clear[0]}');
  }
  final n = clear[1];
  if (n < 1 || n > _chainSlots) {
    throw ArgumentError('a chain carries 1..$_chainSlots keys, claims $n');
  }
  return [
    for (var i = 0; i < n; i++) clear.sublist(2 + i * 32, 2 + (i + 1) * 32),
  ];
}

/// The second door out of a reinstall: the partner's phone still holds the
/// couple key, so it hands it over.
///
/// [KeyEscrow] is the first door and it turns on a password nothing ever
/// verified — a typo at that prompt seals a row nobody alive can open, and says
/// nothing. This one needs no password. The reinstalling phone (D) posts a
/// fresh PUBLIC key and a commitment to six digits it shows on screen; the
/// partner (P) hears those digits on a voice call, types them, and only then
/// seals every key it can decrypt with to that public key.
///
/// What a server with full write access can and cannot do:
///
///   * Delete the row. That is denial of service and nothing here stops it; D
///     simply asks again.
///   * Substitute a public key of its own — and then the digits P types no
///     longer match the commitment, so nothing is ever sealed to it. Six digits
///     spoken between two people who recognise each other is the whole of that
///     protection, and [codeHash] is what stops the commitment being ground out
///     of the row it sits in.
///   * It cannot open the blob, read a seed, or complete the exchange alone.
///
/// There is deliberately no unattended path: no auto-answer, no server-side
/// approval, no push. A couple where one of them is unreachable has no recovery
/// through this door at all, which is the cost of the property above.
class PartnerRewrap {
  PartnerRewrap._();

  static final _aead = Xchacha20.poly1305Aead();

  /// The six digits D shows and P types.
  ///
  /// Left-padded, always: `'000042'` is six characters, and it is the six
  /// characters that go into [codeHash] on both phones.
  static String mintCode() =>
      Random.secure().nextInt(1000000).toString().padLeft(6, '0');

  /// The commitment — Argon2id over the six digits, salted with the raw 32-byte
  /// public key. ~0.5s on the oldest handset, on an isolate.
  ///
  /// SHA-256 is the obvious choice here and it is the wrong one: the public key
  /// sits in the same row as this value, so anyone who can READ the row walks
  /// all 10^6 six-digit preimages in microseconds, then rewrites the row with a
  /// public key of its own and a commitment that passes the digits P types.
  /// Memory-hard turns that sweep into days of 19 MB-hard work inside a
  /// ten-minute window. It does not make six digits sound — nothing does, short
  /// of Signal's sixty — it makes the break funded instead of free.
  static Future<Uint8List> codeHash(String newPublicKeyB64, String code) async {
    final pub = base64Decode(newPublicKeyB64);
    // The RAW key bytes rather than the base64 text, so the two phones cannot
    // disagree about an encoding.
    if (pub.length != 32) {
      throw ArgumentError('a public key is 32 bytes, got ${pub.length}');
    }
    return Uint8List.fromList(
      await compute(argon2idDerive, (secret: code, salt: pub)),
    );
  }

  /// Constant-time: a comparison that stopped at the first wrong byte would let
  /// the digits be walked one at a time.
  static Future<bool> verifyCode(RewrapRequest req, String code) async {
    if (code.length != 6 || req.codeHash.length != 32) return false;
    final expected = await codeHash(req.newPublicKeyB64, code);
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ req.codeHash[i];
    }
    return diff == 0;
  }

  /// D: post a request. Returns the row id, the digits to read aloud, and when
  /// the row stops being answerable.
  ///
  /// Deliberately does NOT publish the new public key. Publishing first rotates
  /// the couple key on both phones with nothing left that can open the past.
  ///
  /// Throws PostgrestException with code 'PT429' when the limiter refuses.
  static Future<(String id, String code, DateTime expiresAt)> open(
    String coupleId,
  ) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) throw StateError('Not signed in');
    final code = mintCode();
    final pub = await CryptoCore.getMyPublicKeyB64();
    // Held BEFORE the insert. The moment the row exists the partner can start
    // answering, and a gap where the request is live but publication is
    // unguarded is the gap this hold exists to close. Rewritten with the real
    // id below; on failure the PREVIOUS hold is put back rather than released
    // — a rate-limited second tap while an earlier request still stands must
    // not walk off with the guard that request is relying on.
    final prior = await CryptoCore.heldRequest();
    await CryptoCore.holdPublication(
      'pending',
      code,
      ServerClock.now().add(const Duration(minutes: 10)),
    );
    final Map<String, dynamic> row;
    final sentAt = DateTime.now().toUtc();
    try {
      row = await SupabaseService.client
          .from('partner_rewrap_requests')
          .insert({
            'couple_id': coupleId,
            'from_user': uid,
            'new_public_key': pub,
            'code_hash': bytesToBytea(await codeHash(pub, code)),
          })
          .select('id, created_at, expires_at')
          .single();
    } catch (_) {
      if (prior != null) {
        await CryptoCore.holdPublication(prior.id, prior.code, prior.until);
      } else {
        await CryptoCore.releasePublication();
      }
      rethrow;
    }
    // The row's own created_at, which Postgres stamped. ServerClock's only
    // other feeder is the presence heartbeat, and that starts with AppShell —
    // which never mounts on the path that leads here. Without this the ten
    // minutes are counted against the raw device clock, and a phone running a
    // few minutes fast shows every code it mints as already "Expired".
    ServerClock.observe(
      DateTime.parse(row['created_at'] as String),
      sentAt: sentAt,
    );
    final id = row['id'] as String;
    final expiresAt = DateTime.parse(row['expires_at'] as String);
    await CryptoCore.holdPublication(id, code, expiresAt);
    return (id, code, expiresAt);
  }

  /// D: this device's own request by id, or null when the row is gone —
  /// expired away, or deleted by a claim that finished before the restart.
  static Future<RewrapRequest?> fetchOwn(String requestId) async {
    final row = await SupabaseService.client
        .from('partner_rewrap_requests')
        .select('id, new_public_key, code_hash, expires_at')
        .eq('id', requestId)
        .maybeSingle();
    return row == null ? null : RewrapRequest.fromRow(row);
  }

  /// P: the newest live, unanswered request from the other half, or null.
  static Future<RewrapRequest?> pending(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;
    final row = await SupabaseService.client
        .from('partner_rewrap_requests')
        .select('id, new_public_key, code_hash, expires_at')
        .eq('couple_id', coupleId)
        // Answering your own request is the attack this ceremony exists to
        // stop; the policy refuses it too, and this keeps it off the screen.
        .neq('from_user', uid)
        .isFilter('wrapped_keys', null)
        // Server-relative: a phone whose clock runs fast would filter out a
        // request that Postgres still considers live, and the ten-minute window
        // is short enough for a minute of skew to swallow it.
        .gt('expires_at', ServerClock.now().toIso8601String())
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : RewrapRequest.fromRow(row);
  }

  /// P: seal every key this device can decrypt with to [req]'s public key.
  ///
  /// The device unlock is demanded HERE and not in the screen, so no later call
  /// site can answer in the background. The second human is the entire security
  /// of this exchange.
  static Future<int> answer(RewrapRequest req) async {
    // Sentences, not diagnostics: the screen shows a StateError's message
    // verbatim rather than guessing which of these it was.
    if (!await AppLock.available()) {
      throw StateError(
        'Set a screen lock on this phone first. The key only ever leaves '
        'after a real unlock, and this phone has none to ask for.',
      );
    }
    if (!await AppLock.authenticate()) {
      throw StateError('That needs your unlock. Nothing was sent.');
    }
    final uid = SupabaseService.currentUserId;
    if (uid == null) throw StateError('Not signed in.');
    final chain = await CryptoCore.exportKeyChainBytes();
    if (chain.isEmpty) {
      throw StateError('This phone has no key to hand over yet.');
    }
    // A full ring beside the derived key is nine, and there are eight slots.
    // The chain is newest-first, so the one left behind is the oldest — which
    // is the one the receiving ring would drop on arrival regardless.
    final box = await _aead.encrypt(
      packChain(chain.take(_chainSlots).toList()),
      secretKey: await CryptoCore.rewrapKey(req.newPublicKeyB64),
      nonce: _aead.newNonce(),
      // The row id, so a blob answered for one request cannot be replayed into
      // another carrying the same public key.
      aad: utf8.encode('rewrap_${req.id}'),
    );
    final sealed = packFull(EncryptedPayload(
      ciphertextB64: base64Encode(box.cipherText),
      nonceB64: base64Encode(box.nonce),
      macB64: base64Encode(box.mac.bytes),
    ),);
    // Before the row is answered, because this is the half that is easy to miss:
    // the moment they publish their new public key, THIS phone stops deriving
    // the key it just handed over, and everything the two of them wrote stops
    // opening here too. Retiring it into the ring is what keeps the history on
    // the phone that still had it. Adopting early is free if the write below
    // fails — the key is still the derived one until they publish.
    final result = await CryptoCore.adoptRetiredKeys(chain);
    final written = await SupabaseService.client
        .from('partner_rewrap_requests')
        .update({
          'wrapped_keys': bytesToBytea(sealed),
          'wrapped_by': uid,
          'wrapped_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', req.id)
        .select('id');
    // A row the policy filtered out is a 204, not an error: the biometric
    // prompt is unbounded and stickyAuth, so crossing the ten-minute line
    // inside it is the ORDINARY way to expire. Without this check the screen
    // said "Sent" over a write the server threw away, and the other phone
    // waited on nothing.
    if (written.isEmpty) {
      throw StateError(
        'Too late — the code expired while this phone was unlocking. '
        'Ask them to start again.',
      );
    }
    return result.dropped;
  }

  /// D: open the answer into the ring, THEN publish, THEN drop the row. Returns
  /// null while the partner has not answered; otherwise how many keys actually
  /// arrived and how many retired keys fell off the end of the ring. Zero
  /// arrivals is the number the screen must not dress up: it means the chain
  /// held nothing this phone did not already derive — a key that had rotated
  /// before the partner sealed it.
  ///
  /// Throws [SecretBoxAuthenticationError] if the blob does not open, with no
  /// fallback of any kind: that means it was sealed to a public key this device
  /// does not hold, and adopting anything at all from there is the one thing
  /// this ceremony must never do.
  static Future<({int added, int dropped})?> claim(
    String requestId,
    String partnerId,
  ) async {
    final row = await SupabaseService.client
        .from('partner_rewrap_requests')
        .select('id, wrapped_keys')
        .eq('id', requestId)
        .maybeSingle();
    if (row == null || row['wrapped_keys'] == null) return null;

    final partnerPub = await SupabaseRepository.fetchPartnerPublicKey(partnerId);
    if (partnerPub == null || partnerPub == CryptoCore.legacyPublicKey) {
      throw StateError(
        "Your partner hasn't enabled Closer yet. Ask them to open it once.",
      );
    }
    final payload = unpackFull(byteaToBytes(row['wrapped_keys']));
    final clear = await _aead.decrypt(
      SecretBox(
        base64Decode(payload.ciphertextB64),
        nonce: base64Decode(payload.nonceB64),
        mac: Mac(base64Decode(payload.macB64)),
      ),
      secretKey: await CryptoCore.rewrapKey(partnerPub),
      aad: utf8.encode('rewrap_$requestId'),
    );
    // Derive BEFORE adopting. Nothing on the claiming side has run
    // ensureSharedKey — this screen is reached before Closer ever is — so
    // without this the current-key exclusion inside adoptRetiredKeys compares
    // against null, and the one arrival it exists to expose (a chain whose
    // only key is the one this phone already derives: the key rotated before
    // the partner sealed it) counts as recovered history.
    await CryptoCore.deriveSharedKey(partnerPublicKeyB64: partnerPub);
    final result = await CryptoCore.adoptRetiredKeys(
      unpackChain(Uint8List.fromList(clear)),
    );
    // Only now, and the hold comes off first because publishMyPublicKey
    // refuses while it is on.
    await CryptoCore.releasePublication();
    // The ring opens their history again, so this phone is no longer the one
    // that cannot read it — the router stops sending it back here, and escrow
    // is allowed to seal the seed this ceremony left it with.
    await CryptoCore.clearKeyless();
    await SupabaseRepository.publishMyPublicKey();
    await SupabaseService.client
        .from('partner_rewrap_requests')
        .delete()
        .eq('id', requestId);
    return result;
  }
}
