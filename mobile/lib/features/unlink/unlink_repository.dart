import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The ceremony's five verbs, and the sealing of the one note.
///
/// Every write goes through a SECURITY DEFINER RPC — the table takes no
/// client writes at all — and the note rides the same couple-key AEAD as
/// chat: ciphertext and nonce columns, never plaintext at rest.
class UnlinkRepository {
  UnlinkRepository._();

  static Future<void> start() =>
      SupabaseService.client.rpc<void>('unlink_start');

  static Future<void> cancel() =>
      SupabaseService.client.rpc<void>('unlink_cancel');

  static Future<void> accept() =>
      SupabaseService.client.rpc<void>('unlink_accept');

  static Future<void> execute() =>
      SupabaseService.client.rpc<void>('unlink_execute');

  /// One function builds the AAD so the sealer and the opener cannot drift —
  /// the bodyAd law. The couple id is the binding: this note means nothing
  /// outside this couple's ceremony.
  @visibleForTesting
  static String noteAd(String coupleId) => 'unlink_note:$coupleId';

  /// Seal and store the partner's note. Empty [text] clears it.
  ///
  /// Throws on failure — unlike chat there is no plaintext fallback and
  /// nothing to fall back TO: the caller shows the shared error state and the
  /// person tries again.
  ///
  /// The CALLER primes the couple key first. `CoupleKey.ready()` below joins a
  /// derive already in flight and starts none, and nothing on the ceremony's
  /// route used to start one — so this reached [CryptoCore.encryptString] with
  /// no key and threw the same StateError on every retry for the whole
  /// process. unlink_screen.dart primes before it calls this and puts the real
  /// reason on screen when the derive says no.
  static Future<void> writeNote(String coupleId, String text) async {
    if (text.trim().isEmpty) {
      await SupabaseService.client.rpc<void>('unlink_write_note', params: {
        'p_cipher': null,
        'p_nonce': null,
      });
      return;
    }
    await CoupleKey.ready();
    final p = await CryptoCore.encryptString(
      text,
      associatedData: noteAd(coupleId),
    );
    final nonce = base64Decode(p.nonceB64);
    final blob = packMacAndCiphertext(p);
    // Refuse the plaintext shape (CryptoCore's old plaintext-v1 sentinel):
    // an all-zero nonce or all-zero MAC would move cleartext into a column
    // named note_cipher and call it encrypted. Layout is mac(16)||ciphertext.
    if (nonce.every((b) => b == 0) || blob.take(16).every((b) => b == 0)) {
      throw StateError('refusing to store an unencrypted note as cipher');
    }
    await SupabaseService.client.rpc<void>('unlink_write_note', params: {
      'p_cipher': bytesToBytea(blob),
      'p_nonce': bytesToBytea(nonce),
    });
  }

  /// The note's text, or null when there is none or it cannot be opened.
  ///
  /// A failure costs the note and nothing else — the ceremony row, its
  /// deadline and its buttons all survive — so this returns null rather than
  /// throwing, and files the failure class so the field is not silent.
  static Future<String?> openNote(UnlinkRow row) async {
    final cipher = row.noteCipherBytea;
    final nonceB = row.noteNonceBytea;
    if (cipher == null || nonceB == null) return null;
    try {
      await CoupleKey.ready();
      final blob = byteaToBytes(cipher);
      final nonce = byteaToBytes(nonceB);
      // Refuse the plaintext sentinel on the way OUT too.
      if (nonce.every((b) => b == 0) ||
          blob.take(16).every((b) => b == 0)) {
        return null;
      }
      final payload = unpackMacAndCiphertext(blob: blob, nonce: nonce);
      return await CryptoCore.decryptString(
        payload,
        associatedData: noteAd(row.coupleId),
      );
    } catch (e, st) {
      ErrorReporter.report(e, st, kind: 'unlink');
      return null;
    }
  }
}
