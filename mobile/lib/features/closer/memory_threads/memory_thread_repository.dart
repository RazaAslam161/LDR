import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/closer_load_result.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    required this.happenedOn,
    required this.state,
    required this.acceptedBy,
    required this.acceptedAt,
    required this.archivedAt,
    required this.createdAt,
    this.deleteRequestedBy,
    this.deleteRequestedAt,
    this.deletePriorState,
    this.photoCipher,
    this.photoNonce,
    this.noteCipher,
    this.noteNonce,
    this.partnerNoteCipher,
    this.partnerNoteNonce,
    this.placeCipher,
    this.placeNonce,
    this.coverPhotoId,
    this.coverPath,
    this.coverTilePath,
    this.photoCount = 0,
    this.lastPhotoAt,
    this.visitId,
  });

  final String id;

  /// Null once the person who proposed it has deleted their account.
  ///
  /// The FK is ON DELETE SET NULL rather than CASCADE precisely so the
  /// surviving partner keeps the memory — a memory is the one object here that
  /// two people own, and deleting one account used to take the other's half
  /// with it.
  final String? proposer;

  final Uint8List titleCipher;
  final Uint8List titleNonce;

  /// The pre-007000 inline photo. Kept forever on the read path: only the
  /// couple's devices hold the key, so no server-side backfill is possible and
  /// these can only be migrated by a device that can already decrypt them.
  final Uint8List? photoCipher;
  final Uint8List? photoNonce;

  final Uint8List? noteCipher;
  final Uint8List? noteNonce;

  /// What the partner wrote when they accepted. A memory carries both sides.
  final Uint8List? partnerNoteCipher;
  final Uint8List? partnerNoteNonce;

  final Uint8List? placeCipher;
  final Uint8List? placeNonce;

  final DateTime happenedOn;
  final MemoryState state;
  final String? acceptedBy;
  final DateTime? acceptedAt;
  final DateTime? archivedAt;
  final DateTime createdAt;
  final String? deleteRequestedBy;
  final DateTime? deleteRequestedAt;

  /// Where a cancelled deletion returns to. Without it, cancelling on an
  /// archived memory silently un-archived it.
  final String? deletePriorState;

  /// Denormalised onto the parent by trigger so the timeline reaches a cover in
  /// ONE query — the paths live on `memory_photos`, and "position 0 of each of
  /// these fifty parents" is not something PostgREST can express without N+1.
  final String? coverPhotoId;
  final String? coverPath;
  final String? coverTilePath;
  final int photoCount;
  final DateTime? lastPhotoAt;

  final String? visitId;

  EncryptedPayload titlePayload() => _unpack(titleCipher, titleNonce);
  EncryptedPayload? photoPayload() => photoCipher == null || photoNonce == null
      ? null
      : _unpack(photoCipher!, photoNonce!);
  EncryptedPayload? notePayload() => noteCipher == null || noteNonce == null
      ? null
      : _unpack(noteCipher!, noteNonce!);
  EncryptedPayload? partnerNotePayload() =>
      partnerNoteCipher == null || partnerNoteNonce == null
          ? null
          : _unpack(partnerNoteCipher!, partnerNoteNonce!);
  EncryptedPayload? placePayload() => placeCipher == null || placeNonce == null
      ? null
      : _unpack(placeCipher!, placeNonce!);

  static EncryptedPayload _unpack(Uint8List blob, Uint8List nonce) =>
      unpackMacAndCiphertext(blob: blob, nonce: nonce);

  static MemoryThread fromJson(Map<String, dynamic> json) {
    return MemoryThread(
      id: JsonUtils.parseString(json['id']),
      proposer: JsonUtils.parseStringOrNull(json['proposer']),
      titleCipher: byteaToBytes(json['title_cipher']),
      titleNonce: byteaToBytes(json['title_nonce']),
      photoCipher: _maybeBytes(json['photo_cipher']),
      photoNonce: _maybeBytes(json['photo_nonce']),
      noteCipher: _maybeBytes(json['note_cipher']),
      noteNonce: _maybeBytes(json['note_nonce']),
      partnerNoteCipher: _maybeBytes(json['partner_note_cipher']),
      partnerNoteNonce: _maybeBytes(json['partner_note_nonce']),
      placeCipher: _maybeBytes(json['place_cipher']),
      placeNonce: _maybeBytes(json['place_nonce']),
      happenedOn: JsonUtils.parseDate(json['happened_on']).toUtc(),
      state: _parseState(JsonUtils.parseString(json['state'])),
      acceptedBy: JsonUtils.parseStringOrNull(json['accepted_by']),
      acceptedAt: JsonUtils.parseDateOrNull(json['accepted_at'])?.toUtc(),
      archivedAt: JsonUtils.parseDateOrNull(json['archived_at'])?.toUtc(),
      createdAt: JsonUtils.parseDate(json['created_at']).toUtc(),
      deleteRequestedBy:
          JsonUtils.parseStringOrNull(json['delete_requested_by']),
      deleteRequestedAt:
          JsonUtils.parseDateOrNull(json['delete_requested_at'])?.toUtc(),
      deletePriorState: JsonUtils.parseStringOrNull(json['delete_prior_state']),
      coverPhotoId: JsonUtils.parseStringOrNull(json['cover_photo_id']),
      coverPath: JsonUtils.parseStringOrNull(json['cover_path']),
      coverTilePath: JsonUtils.parseStringOrNull(json['cover_tile_path']),
      photoCount: (json['photo_count'] as num?)?.toInt() ?? 0,
      lastPhotoAt: JsonUtils.parseDateOrNull(json['last_photo_at'])?.toUtc(),
      visitId: JsonUtils.parseStringOrNull(json['visit_id']),
    );
  }

  static Uint8List? _maybeBytes(dynamic v) =>
      v == null ? null : byteaToBytes(v);
}

/// All Supabase reads/writes for Memory Threads. Every field is encrypted
/// on-device before insert; only `bytea` ciphertext + nonce leave the client.
///
/// Every lifecycle transition goes through a SECURITY DEFINER RPC. That is not
/// tidiness: `authenticated` holds no table-level UPDATE and no DELETE on
/// `memory_threads` at all, so a direct write to `state`, `accepted_by` or
/// `deleted_at` is a 403 by construction. Dual consent used to be one `if` in
/// the screen over a policy that permitted the row to be rewritten any way at
/// all; now the assertion "only the OTHER partner may confirm" lives in one
/// line of SQL that the client cannot reach around.
class MemoryThreadRepository {
  MemoryThreadRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  /// Named columns, and deliberately NOT `select()`.
  ///
  /// The old query selected every column, which meant `photo_cipher` — nine
  /// rows averaging 352 KB, rendered by PostgREST as `\x`+hex at two characters
  /// per byte, re-sent on every realtime tick because the table is REPLICA
  /// IDENTITY FULL. Twenty memories was roughly 14 MB of JSON to paint a list
  /// of titles, on a screen that never showed a photograph.
  ///
  /// `photo_cipher` is excluded here on purpose: the legacy inline photo is
  /// fetched per-row, only when something is actually going to display it.
  /// `photo_nonce` IS fetched, at 24 bytes a row, and `photo_cipher` is not.
  /// The pair CHECK constraint added in 007000 makes the nonce an exact,
  /// nearly-free predicate for "this row still has a legacy inline photo" —
  /// without it the timeline cannot tell a photo-less memory from one whose
  /// photograph simply was not selected, and every legacy picture silently
  /// disappears from the screen.
  static const _columns = 'id,proposer,title_cipher,title_nonce,photo_nonce,'
      'note_cipher,note_nonce,happened_on,state,accepted_by,accepted_at,'
      'archived_at,created_at,delete_requested_by,delete_requested_at,'
      'delete_prior_state,cover_photo_id,cover_path,cover_tile_path,'
      'photo_count,last_photo_at,visit_id,place_cipher,place_nonce,'
      'partner_note_cipher,partner_note_nonce';

  /// Two screens' worth of cards. A short page is the end of the shelf.
  static const _pageSize = 60;

  /// One page of live + archived threads for [coupleId], newest first, from
  /// [before] on `happened_on` back. Deleted rows are excluded server-side.
  ///
  /// The bound is inclusive because `happened_on` is a DATE and a day can hold
  /// several memories: an exclusive cursor would step over every one of them
  /// that fell after a page boundary. The caller keys by id, so the overlap
  /// costs one repeated row and loses none.
  static Future<CloserLoadResult<MemoryThread>> fetchThreads(
    String coupleId, {
    DateTime? before,
  }) async {
    var q = _c
        .from('memory_threads')
        .select(_columns)
        .eq('couple_id', coupleId)
        .neq('state', _stringifyState(MemoryState.deleted));
    if (before != null) {
      q = q.lte('happened_on', before.toIso8601String().split('T').first);
    }

    final res =
        await q.order('happened_on', ascending: false).limit(_pageSize);

    final threads = <MemoryThread>[];
    var unreadable = 0;
    for (final row in res as List) {
      try {
        threads.add(MemoryThread.fromJson(JsonUtils.asMap(row)));
      } catch (e) {
        unreadable++;
        debugPrint('memory threads: unreadable row: ${e.runtimeType}');
      }
    }
    return CloserLoadResult(
      List<MemoryThread>.unmodifiable(threads),
      unreadable: unreadable,
    );
  }

  /// How many proposals are waiting for THIS user to answer.
  ///
  /// `state` and `proposer` are both plaintext, so this needs no key, no
  /// decryption and no PIN — which is what lets the Closer grid show a count on
  /// a tile that is otherwise sealed behind one.
  static Future<int> pendingProposalCount({
    required String coupleId,
    required String me,
  }) async {
    try {
      final res = await _c
          .from('memory_threads')
          .select('id')
          .eq('couple_id', coupleId)
          .eq('state', _stringifyState(MemoryState.proposed))
          .neq('proposer', me)
          .count(CountOption.exact);
      return res.count;
    } catch (e) {
      // A badge is not worth a broken grid.
      debugPrint('memory threads: count failed: ${e.runtimeType}');
      return 0;
    }
  }

  /// Realtime threads for [coupleId], as a DELTA rather than a re-read.
  ///
  /// `.stream()` re-emitted the entire table on every change and the screen
  /// rebuilt every card from scratch, so one partner tapping Accept re-parsed
  /// and re-decrypted every row on both devices. Here the first fetch seeds a
  /// map and each change patches one entry.
  ///
  /// Built on [ManagedSubscription] so a socket reconnect rebuilds the channel
  /// cleanly instead of leaving a duplicate-topic channel that is joined and
  /// dead — the app-wide subscription-health bug.
  static Stream<CloserLoadResult<MemoryThread>> streamThreads(String coupleId) {
    final byId = <String, MemoryThread>{};
    var unreadable = 0;
    var open = false;
    ManagedSubscription? sub;
    late final StreamController<CloserLoadResult<MemoryThread>> controller;

    CloserLoadResult<MemoryThread> snapshot() {
      final live = byId.values
          .where((t) => t.state != MemoryState.deleted)
          .toList()
        ..sort((a, b) => b.happenedOn.compareTo(a.happenedOn));
      return CloserLoadResult(
        List<MemoryThread>.unmodifiable(live),
        unreadable: unreadable,
      );
    }

    void apply(PostgresChangePayload payload) {
      try {
        switch (payload.eventType) {
          case PostgresChangeEvent.delete:
            final id = payload.oldRecord['id'];
            if (id != null) byId.remove(JsonUtils.parseString(id));
          case PostgresChangeEvent.insert:
          case PostgresChangeEvent.update:
            final row = MemoryThread.fromJson(payload.newRecord);
            byId[row.id] = row;
          case PostgresChangeEvent.all:
            return;
        }
      } catch (e) {
        debugPrint('memory threads delta: ${e.runtimeType}');
        return;
      }
      if (open) controller.add(snapshot());
    }

    controller = StreamController<CloserLoadResult<MemoryThread>>.broadcast(
      onListen: () async {
        // Subscribe BEFORE the seed read, so a change landing between the two
        // is applied on top of it rather than lost in the gap.
        open = true;
        sub = ManagedSubscription.start(
          () => RealtimeService.coupleTable(
            channelName: 'memories:$coupleId',
            table: 'memory_threads',
            coupleId: coupleId,
            onChange: apply,
          ),
        );
        DateTime? cursor;
        try {
          // Pages are chased, not waited for: the first emits the moment it
          // lands and the list grows underneath it, so a long history costs a
          // constant amount per round trip without a spinner between them.
          while (open) {
            final seed = await fetchThreads(coupleId, before: cursor);
            if (!open) return;
            unreadable += seed.unreadable;
            for (final t in seed.items) {
              byId.putIfAbsent(t.id, () => t);
            }
            controller.add(snapshot());
            if (seed.items.length + seed.unreadable < _pageSize) return;
            final next = seed.items.isEmpty ? null : seed.items.last.happenedOn;
            // A whole page sitting on one date, or none of it readable: there
            // is nothing left to key on and asking again returns the same rows.
            if (next == null || next == cursor) return;
            cursor = next;
          }
        } catch (e) {
          if (open) controller.addError(e);
        }
      },
      onCancel: () {
        // Leaving the screen mid-page has to stop the pager too, or it keeps
        // reading a list nobody is looking at to its last row.
        open = false;
        sub?.dispose();
        sub = null;
      },
    );
    return controller.stream;
  }

  /// Propose a new memory (state = `proposed`). Awaits the partner's accept.
  ///
  /// All fields are encrypted with the item UUID as associated data; the UUID
  /// is generated client-side so it can be used as AD before insert.
  ///
  /// The insert fires `notify_memory`, which is the entire reason this feature
  /// had nine proposals and zero acceptances — nothing had ever told the
  /// partner one existed.
  static Future<String> propose({
    required String coupleId,
    required String proposer,
    required String title,
    required DateTime happenedOn,
    String? note,
    String? place,
    String? visitId,
    Uint8List? photoBytes,
  }) async {
    final itemId = _generateUuid();
    final titlePayload =
        await CryptoCore.encryptString(title, associatedData: itemId);
    final titleBlob = packMacAndCiphertext(titlePayload);
    final titleNonceBytes =
        Uint8List.fromList(base64Decode(titlePayload.nonceB64));

    final note0 = await _sealText(note, '${itemId}_note');
    final place0 = await _sealText(place, '${itemId}_place');

    // The pre-007000 shape. New photos belong in memory_photos as separate
    // storage objects; this stays only so the composer keeps working until that
    // path lands, and heal-on-read migrates whatever it writes.
    Uint8List? photoBlob;
    Uint8List? photoNonceBytes;
    if (photoBytes != null) {
      final photoPayload = await CryptoCore.encryptBytesOffThread(
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
      if (note0 != null) 'note_cipher': bytesToBytea(note0.blob),
      if (note0 != null) 'note_nonce': bytesToBytea(note0.nonce),
      if (place0 != null) 'place_cipher': bytesToBytea(place0.blob),
      if (place0 != null) 'place_nonce': bytesToBytea(place0.nonce),
      if (photoBlob != null) 'photo_cipher': bytesToBytea(photoBlob),
      if (photoNonceBytes != null) 'photo_nonce': bytesToBytea(photoNonceBytes),
      if (visitId != null) 'visit_id': visitId,
      'state': _stringifyState(MemoryState.proposed),
    });

    return itemId;
  }

  /// The partner accepts. ONE TAP: [note] is optional and the fast path passes
  /// nothing, because making the only transition that was running at zero more
  /// expensive is the opposite of a fix.
  static Future<void> accept(String threadId, {String? note}) async {
    final sealed = await _sealText(note, '${threadId}_pnote');
    await _c.rpc<void>('memory_accept', params: {
      'p_id': threadId,
      'p_note_cipher': sealed == null ? null : bytesToBytea(sealed.blob),
      'p_note_nonce': sealed == null ? null : bytesToBytea(sealed.nonce),
    });
  }

  /// Either partner archives (non-destructive). Recoverable.
  static Future<void> archive(String threadId) =>
      _c.rpc<void>('memory_set_state',
          params: {'p_id': threadId, 'p_state': 'archived'});

  /// Un-archive back to live.
  static Future<void> unarchive(String threadId) =>
      _c.rpc<void>('memory_set_state',
          params: {'p_id': threadId, 'p_state': 'accepted'});

  /// Take back your own proposal.
  ///
  /// This verb did not exist, and its absence is why all nine production rows
  /// were stuck: the proposer's own pending memory rendered an empty action row,
  /// so the person who created it could neither complete it nor withdraw it.
  static Future<void> withdraw(String threadId) =>
      _c.rpc<void>('memory_withdraw', params: {'p_id': threadId});

  /// Ask to delete. Dual consent — this only opens the request.
  static Future<void> requestDeletion(String threadId) =>
      _c.rpc<void>('memory_request_delete', params: {'p_id': threadId});

  /// Cancel a deletion request. EITHER partner can, which is what the
  /// repository always claimed ("either can veto by cancelling") while the UI
  /// showed the button to the requester alone.
  static Future<void> cancelDeletion(String threadId) =>
      _c.rpc<void>('memory_cancel_delete', params: {'p_id': threadId});

  /// Confirm your partner's deletion request. The RPC refuses if you are the
  /// one who asked — that single condition is the whole dual-consent
  /// guarantee, and it cannot live in the client.
  static Future<void> confirmDeletion(String threadId) =>
      _c.rpc<void>('memory_confirm_delete', params: {'p_id': threadId});

  /// Encrypts [text] and returns the packed blob plus its nonce, or null when
  /// there is nothing to write.
  static Future<({Uint8List blob, Uint8List nonce})?> _sealText(
    String? text,
    String associatedData,
  ) async {
    if (text == null || text.trim().isEmpty) return null;
    final payload =
        await CryptoCore.encryptString(text, associatedData: associatedData);
    return (
      blob: packMacAndCiphertext(payload),
      nonce: Uint8List.fromList(base64Decode(payload.nonceB64)),
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
  return CryptoCore.decryptString(
    thread.titlePayload(),
    associatedData: thread.id,
  );
}

/// Decrypts the optional note. Returns null if there isn't one.
Future<String?> decryptNote(MemoryThread thread) async {
  final payload = thread.notePayload();
  if (payload == null) return null;
  return CryptoCore.decryptString(
    payload,
    associatedData: '${thread.id}_note',
  );
}

/// Decrypts the legacy inline photo. Returns null if there isn't one.
///
/// [MemoryThreadRepository._columns] does not fetch `photo_cipher`, so a thread
/// from the list has none even when the row does; this re-reads the one row
/// that is about to be displayed.
Future<Uint8List?> decryptPhoto(MemoryThread thread) async {
  var payload = thread.photoPayload();
  if (payload == null) {
    final row = await SupabaseService.client
        .from('memory_threads')
        .select('photo_cipher,photo_nonce')
        .eq('id', thread.id)
        .maybeSingle();
    final cipher = row?['photo_cipher'];
    final nonce = row?['photo_nonce'];
    if (cipher == null || nonce == null) return null;
    payload = unpackMacAndCiphertext(
      blob: byteaToBytes(cipher),
      nonce: byteaToBytes(nonce),
    );
  }
  return CryptoCore.decryptBytes(
    payload,
    associatedData: '${thread.id}_photo',
  );
}
