import 'dart:convert';
import 'dart:typed_data';

import 'package:miles/core/crypto_core.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// One pin on the body map, with decrypted note.
class BodyMapPin {
  BodyMapPin({
    required this.id,
    required this.authorId,
    required this.x,
    required this.y,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String authorId;
  final double x; // 0..1 normalized
  final double y; // 0..1 normalized
  final String note;
  final DateTime createdAt;
}

/// DB access for Body Map. Notes are XChaCha20-Poly1305 encrypted client-side.
class BodyMapRepository {
  BodyMapRepository._();

  static final _c = SupabaseService.client;

  static Future<void> ensureSharedKey(SessionState session) async {
    final partner = session.partner;
    if (partner == null) {
      throw StateError('Partner not linked — cannot derive shared key.');
    }
    final partnerPub = await SupabaseRepository.fetchPartnerPublicKey(partner.id);
    if (partnerPub == null) {
      throw StateError(
        'Partner has not published a key yet. Ask them to open Closer once.',
      );
    }
    await CryptoCore.deriveSharedKey(partnerPublicKeyB64: partnerPub);
  }

  // Poly1305 MAC (16 bytes) is appended to the ciphertext — single bytea column.
  static String _pack(EncryptedPayload p) {
    final ct = base64Decode(p.ciphertextB64);
    final mac = base64Decode(p.macB64);
    final combined = Uint8List(ct.length + mac.length);
    combined.setRange(0, ct.length, ct);
    combined.setRange(ct.length, combined.length, mac);
    return bytesToBytea(combined);
  }

  static EncryptedPayload _unpack(dynamic cipherVal, dynamic nonceVal) {
    final combined = byteaToBytes(cipherVal);
    final ct = combined.sublist(0, combined.length - 16);
    final mac = combined.sublist(combined.length - 16);
    return EncryptedPayload(
      ciphertextB64: base64Encode(ct),
      nonceB64: base64Encode(byteaToBytes(nonceVal)),
      macB64: base64Encode(mac),
    );
  }

  static Future<void> addPin({
    required String coupleId,
    required String authorId,
    required double x,
    required double y,
    required String note,
  }) async {
    final payload = await CryptoCore.encryptString(
      note,
      associatedData: authorId,
    );
    await _c.from('body_map_pins').insert({
      'couple_id': coupleId,
      'author': authorId,
      'x': x,
      'y': y,
      'note_cipher': _pack(payload),
      'note_nonce': bytesToBytea(base64Decode(payload.nonceB64)),
    });
  }

  static Future<void> deletePin({required String pinId}) async {
    await _c.from('body_map_pins').delete().eq('id', pinId);
  }

  /// Fetches + decrypts every pin in the couple (mine + partner's).
  static Future<List<BodyMapPin>> fetchPins({
    required String coupleId,
  }) async {
    final rows = await _c
        .from('body_map_pins')
        .select('id, author, x, y, note_cipher, note_nonce, created_at')
        .eq('couple_id', coupleId)
        .order('created_at', ascending: true);

    final out = <BodyMapPin>[];
    for (final row in rows as List) {
      try {
        final authorId = JsonUtils.parseString(row['author']);
        final note = await CryptoCore.decryptString(
          _unpack(row['note_cipher'], row['note_nonce']),
          associatedData: authorId,
        );
        out.add(BodyMapPin(
          id: JsonUtils.parseString(row['id']),
          authorId: authorId,
          x: JsonUtils.parseDouble(row['x']),
          y: JsonUtils.parseDouble(row['y']),
          note: note,
          createdAt: JsonUtils.parseDate(row['created_at']).toLocal(),
        ),);
      } catch (_) {
        continue;
      }
    }
    return out;
  }
}
