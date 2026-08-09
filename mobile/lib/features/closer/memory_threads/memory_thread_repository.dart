import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:miles/features/closer/closer_load_result.dart';
import 'package:miles/core/crypto_core.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// Lifecycle of a memory thread row. Matches the `state` text column.
/// Spec §F9: `proposed → accepted (live) → archived`,
/// with `deletion_requested → deleted` branching off accepted.
enum MemoryState { proposed, accepted, archived, deletionRequested, deleted }

MemoryState _parseState(String s) {
  switch (s) {
    case 'proposed':
      return MemoryState.proposed;
    case 'accepted':
      return MemoryState.accepted;
    case 'archived':
      return MemoryState.archived;
    case 'deletion_requested':
      return MemoryState.deletionRequested;
    case 'deleted':
      return MemoryState.deleted;
    default:
      return MemoryState.proposed;
  }
}

String _stringifyState(MemoryState s) {
  switch (s) {
    case MemoryState.proposed:
      return 'proposed';
    case MemoryState.accepted:
      return 'accepted';
    case MemoryState.archived:
      return 'archived';
    case MemoryState.deletionRequested:
      return 'deletion_requested';
    case MemoryState.deleted:
      return 'deleted';
  }
}

/// Decrypted-in-memory representation of a `memory_threads` row. Ciphertext
/// bytes are kept raw so the screen decrypts lazily and never holds more than
/// one item's plaintext at a time.
class MemoryThread {
  MemoryThread({
    required this.id,
    required this.proposer,
    required this.titleCipher,
    required this.titleNonce,
    required this.happenedOn, required this.state, required this.acceptedBy, required this.acceptedAt, required this.archivedAt, required this.createdAt, this.photoCipher,
    this.photoNonce,
    this.noteCipher,
    this.noteNonce,
  });

  final String id;
  final String proposer;
  final Uint8List titleCipher;
  final Uint8List titleNonce;
  final Uint8List? photoCipher;
  final Uint8List? photoNonce;
  final Uint8List? noteCipher;
  final Uint8List? noteNonce;
  final DateTime happenedOn;
  final MemoryState state;
  final String? acceptedBy;
  final DateTime? acceptedAt;
  final DateTime? archivedAt;
  final DateTime createdAt;

  EncryptedPayload titlePayload() => _unpack(titleCipher, titleNonce);
  EncryptedPayload? photoPayload() =>
      photoCipher == null || photoNonce == null
          ? null
          : _unpack(photoCipher!, photoNonce!);
  EncryptedPayload? notePayload() => noteCipher == null || noteNonce == null
      ? null
      : _unpack(noteCipher!, noteNonce!);

  static EncryptedPayload _unpack(Uint8List blob, Uint8List nonce) =>
      unpackMacAndCiphertext(blob: blob, nonce: nonce);

  static MemoryThread fromJson(Map<String, dynamic> json) {
    return MemoryThread(
      id: JsonUtils.parseString(json['id']),
      proposer: JsonUtils.parseString(json['proposer']),
      titleCipher: byteaToBytes(json['title_cipher']),
      titleNonce: byteaToBytes(json['title_nonce']),
      photoCipher: _maybeBytes(json['photo_cipher']),
      photoNonce: _maybeBytes(json['photo_nonce']),
      noteCipher: _maybeBytes(json['note_cipher']),
      noteNonce: _maybeBytes(json['note_nonce']),
      happenedOn: JsonUtils.parseDate(json['happened_on']).toUtc(),
      state: _parseState(JsonUtils.parseString(json['state'])),
      acceptedBy: JsonUtils.parseStringOrNull(json['accepted_by']),
      acceptedAt: JsonUtils.parseDateOrNull(json['accepted_at'])?.toUtc(),
      archivedAt: JsonUtils.parseDateOrNull(json['archived_at'])?.toUtc(),
      createdAt: JsonUtils.parseDate(json['created_at']).toUtc(),
    );
  }

  static Uint8List? _maybeBytes(dynamic v) => v == null ? null : byteaToBytes(v);
}

class MemoryRevisit {
  MemoryRevisit({
    required this.memoryId,
    required this.initiatedBy,
    required this.initiatedAt,
    this.partnerAcknowledgedAt,
  });

  final String memoryId;
  final String initiatedBy;
  final DateTime initiatedAt;
  final DateTime? partnerAcknowledgedAt;
}

/// All Supabase reads/writes for Memory Threads. Every field is encrypted
/// on-device before insert; only `bytea` ciphertext + nonce leave the client.
class MemoryThreadRepository {
  MemoryThreadRepository._();

  static final _c = SupabaseService.client;

  /// Live + archived threads for [coupleId]. Deleted rows are excluded.
  /// Ordered newest-first by `happened_on` so the timeline reads top-down.
  static Future<CloserLoadResult<MemoryThread>> fetchThreads(
      String coupleId) async {
    final res = await _c
        .from('memory_threads')
        .select()
        .eq('couple_id', coupleId)
        .neq('state', _stringifyState(MemoryState.deleted))
        .order('happened_on', ascending: false);

    final threads = <MemoryThread>[];
    var unreadable = 0;
    for (final row in res as List) {
      try {
        threads.add(MemoryThread.fromJson(JsonUtils.asMap(row)));
      } catch (e) {
        unreadable++;
        debugPrint('memory threads: unreadable row: $e');
      }
    }
    return CloserLoadResult(
      List<MemoryThread>.unmodifiable(threads),
      unreadable: unreadable,
    );
  }

  /// Propose a new memory (state = `proposed`). Awaits partner's accept.
  /// All fields are encrypted with the item UUID as associated data; the UUID
  /// is generated client-side so it can be used as AD before insert.
  static Future<String> propose({
    required String coupleId,
    required String proposer,
    required String title,
    required DateTime happenedOn,
    String? note,
    Uint8List? photoBytes,
  }) async {
    final itemId = _generateUuid();
    final titlePayload =
        await CryptoCore.encryptString(title, associatedData: itemId);
    final titleBlob = packMacAndCiphertext(titlePayload);
    final titleNonceBytes = Uint8List.fromList(base64Decode(titlePayload.nonceB64));

    Uint8List? noteBlob;
    Uint8List? noteNonceBytes;
    if (note != null && note.trim().isNotEmpty) {
      final notePayload =
          await CryptoCore.encryptString(note, associatedData: '${itemId}_note');
      noteBlob = packMacAndCiphertext(notePayload);
      noteNonceBytes = Uint8List.fromList(base64Decode(notePayload.nonceB64));
    }

    Uint8List? photoBlob;
    Uint8List? photoNonceBytes;
    if (photoBytes != null) {
      final photoPayload = await CryptoCore.encryptBytes(
        photoBytes,
        associatedData: '${itemId}_photo',
      );
      photoBlob = packMacAndCiphertext(photoPayload);
      photoNonceBytes = Uint8List.fromList(base64Decode(photoPayload.nonceB64));
    }

    final happenedStr =
        '${happenedOn.year}-${happenedOn.month.toString().padLeft(2, '0')}-${happenedOn.day.toString().padLeft(2, '0')}';

    await _c.from('memory_threads').insert({
      'id': itemId,
      'couple_id': coupleId,
      'proposer': proposer,
      'title_cipher': bytesToBytea(titleBlob),
      'title_nonce': bytesToBytea(titleNonceBytes),
      'happened_on': happenedStr,
      if (noteBlob != null) 'note_cipher': bytesToBytea(noteBlob),
      if (noteNonceBytes != null) 'note_nonce': bytesToBytea(noteNonceBytes),
      if (photoBlob != null) 'photo_cipher': bytesToBytea(photoBlob),
      if (photoNonceBytes != null) 'photo_nonce': bytesToBytea(photoNonceBytes),
      'state': _stringifyState(MemoryState.proposed),
    });

    return itemId;
  }

  /// Partner accepts the proposal → memory becomes live (`accepted`).
  static Future<void> accept({
    required String threadId,
    required String acceptedBy,
  }) async {
    await _c.from('memory_threads').update({
      'state': _stringifyState(MemoryState.accepted),
      'accepted_by': acceptedBy,
      'accepted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', threadId);
  }

  /// Either partner archives (non-destructive). Recoverable.
  static Future<void> archive(String threadId) async {
    await _c.from('memory_threads').update({
      'state': _stringifyState(MemoryState.archived),
      'archived_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', threadId);
  }

  /// Un-archive back to live.
  static Future<void> unarchive(String threadId) async {
    await _c.from('memory_threads').update({
      'state': _stringifyState(MemoryState.accepted),
      'archived_at': null,
    }).eq('id', threadId);
  }

  /// Request deletion — dual consent. Marks the row as `deletion_requested`.
  static Future<void> requestDeletion(String threadId) async {
    await _c.from('memory_threads').update({
      'state': _stringifyState(MemoryState.deletionRequested),
    }).eq('id', threadId);
  }

  /// Cancel a deletion request (restore to accepted). Either partner can do
  /// this — the spec treats deletion as needing mutual consent, so either can
  /// veto by cancelling.
  static Future<void> cancelDeletion(String threadId) async {
    await _c.from('memory_threads').update({
      'state': _stringifyState(MemoryState.accepted),
    }).eq('id', threadId);
  }

  /// Hard delete after mutual consent (or partner-initiated escape hatch).
  /// We set `state = deleted` so a future purge job can vacuum these.
  static Future<void> hardDelete(String threadId) async {
    await _c.from('memory_threads').update({
      'state': _stringifyState(MemoryState.deleted),
    }).eq('id', threadId);
  }

  /// "Revisit together" — records that [initiatedBy] wants to revisit this
  /// memory with their partner. Partner acknowledges on next open.
  static Future<void> requestRevisit({
    required String threadId,
    required String initiatedBy,
  }) async {
    await _c.from('memory_revisits').upsert({
      'memory_id': threadId,
      'initiated_by': initiatedBy,
      'initiated_at': DateTime.now().toUtc().toIso8601String(),
      'partner_acknowledged_at': null,
    });
  }

  /// Partner confirms the revisit (clears the prompt on their side).
  static Future<void> acknowledgeRevisit(String threadId) async {
    await _c.from('memory_revisits').update({
      'partner_acknowledged_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('memory_id', threadId);
  }

  /// Returns the open revisit request for [threadId], if any.
  static Future<MemoryRevisit?> fetchRevisit(String threadId) async {
    final res = await _c
        .from('memory_revisits')
        .select()
        .eq('memory_id', threadId)
        .maybeSingle();
    if (res == null) return null;
    final json = res;
    return MemoryRevisit(
      memoryId: JsonUtils.parseString(json['memory_id']),
      initiatedBy: JsonUtils.parseString(json['initiated_by']),
      initiatedAt: JsonUtils.parseDate(json['initiated_at']).toUtc(),
      partnerAcknowledgedAt:
          JsonUtils.parseDateOrNull(json['partner_acknowledged_at'])?.toUtc(),
    );
  }

  // v4 UUID generator (RFC 4122 §4.4). Uses [Random.secure] for cryptographic
  // randomness so item ids aren't predictable — important because the id is
  // bound as associated data to the ciphertext.
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

// NOTE: these MUST pass the same associated-data the propose() step used
// (the item id), or the Poly1305 MAC check fails with "could not decrypt".

/// Decrypts the title of [thread] for display.
Future<String> decryptTitle(MemoryThread thread) async {
  return CryptoCore.decryptString(thread.titlePayload(),
      associatedData: thread.id);
}

/// Decrypts the optional note. Returns null if there isn't one.
Future<String?> decryptNote(MemoryThread thread) async {
  final payload = thread.notePayload();
  if (payload == null) return null;
  return CryptoCore.decryptString(payload,
      associatedData: '${thread.id}_note');
}

/// Decrypts the optional photo. Returns null if there isn't one.
Future<Uint8List?> decryptPhoto(MemoryThread thread) async {
  final payload = thread.photoPayload();
  if (payload == null) return null;
  return CryptoCore.decryptBytes(payload,
      associatedData: '${thread.id}_photo');
}
