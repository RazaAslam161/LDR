import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/data/couple_key.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/media/thumbnails.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/chat/voice_peaks.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';


/// Flip to true to log realtime channel-join status to the console (for the
/// 2-device subscription-health test). Compile-time const → dead-code-eliminated
/// in release when false.
const bool kRtChatDebug = false;

/// A single chat message between the two partners.
///
/// [kind] is one of: 'text', 'image', 'voice', 'video', 'file'.
/// - text: [body] holds the message
/// - image: [imagePath] is the storage path; the public URL is derived
/// - voice: [voicePath] is the storage path; client plays it back
/// - video: [videoPath] is in the PRIVATE couple_intimate bucket (signed URL)
/// - file: [filePath] is in couple_files; [body] is the file's NAME
/// Delivery state for an outgoing message shown optimistically.
enum SendStatus { sent, sending, failed }

class Message {
  Message({
    required this.id,
    required this.senderId,
    required this.createdAt,
    this.body,
    this.imagePath,
    this.voicePath,
    this.voiceDurationMs,
    this.voicePeaks,
    this.videoPath,
    this.filePath,
    this.fileSize,
    this.replyToId,
    this.kind = 'text',
    this.deletedForEveryone = false,
    this.deletedBy = const [],
    this.localPath,
    this.sendStatus = SendStatus.sent,
    this.seq = 0,
    this.albumId,
    this.hasThumb = false,
    this.bodyCipher,
    this.bodyNonce,
    this.bodyUndecryptable = false,
    this.editedAt,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: JsonUtils.parseString(j['id']),
        senderId: JsonUtils.parseString(j['sender_id']),
        body: JsonUtils.parseStringOrNull(j['body']),
        // Bytes only. Decryption is async and MUST NOT happen here: _parseRows
        // drops any row whose decode throws, so a decrypt failure inside this
        // factory would delete messages from the screen whose correct plaintext
        // is sitting in `body` on the very same row. Hydration is a separate
        // pass that cannot drop anything — see [ChatRepository.hydrate].
        bodyCipher: _maybeBytes(j['body_cipher']),
        bodyNonce: _maybeBytes(j['body_nonce'], expect: kNonceLength),
        imagePath: JsonUtils.parseStringOrNull(j['image_path']),
        voicePath: JsonUtils.parseStringOrNull(j['voice_path']),
        voiceDurationMs: j['voice_duration_ms'] == null
            ? null
            : JsonUtils.parseInt(j['voice_duration_ms']),
        voicePeaks: JsonUtils.parseStringOrNull(j['voice_peaks']),
        videoPath: JsonUtils.parseStringOrNull(j['video_path']),
        filePath: JsonUtils.parseStringOrNull(j['file_path']),
        fileSize: j['file_size'] == null ? null : JsonUtils.parseInt(j['file_size']),
        replyToId: JsonUtils.parseStringOrNull(j['reply_to_id']),
        kind: JsonUtils.parseString(j['kind'], fallback: 'text'),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
        seq: JsonUtils.parseInt(j['seq']),
        deletedForEveryone: JsonUtils.parseBool(j['deleted_for_everyone']),
        deletedBy: j['deleted_by'] is List
            ? (j['deleted_by'] as List).map((e) => e.toString()).toList()
            : const [],
        albumId: JsonUtils.parseStringOrNull(j['album_id']),
        hasThumb: JsonUtils.parseBool(j['has_thumb']),
        // Every select here is a bare .select(), so this column already
        // arrived on the wire and was simply dropped on the floor.
        editedAt: j['edited_at'] == null
            ? null
            : JsonUtils.parseDate(j['edited_at']).toLocal(),
      );

  /// `mac || ciphertext` for [body], and its nonce. Null on every row written
  /// before chat encryption, and on every row written by a client that has no
  /// couple key — which the release gate cannot rule out, because it fails
  /// open. Both stay null today: nothing writes them yet.
  final Uint8List? bodyCipher;
  final Uint8List? bodyNonce;

  /// This row carried ciphertext and it could not be opened — a key this device
  /// does not have, or a corrupt column.
  ///
  /// Distinct from `body == null`, and the distinction is the point: an empty
  /// bubble is indistinguishable from data loss, so the UI renders a stated
  /// "can't open this" instead of nothing at all.
  final bool bodyUndecryptable;

  /// Never throws, so a malformed cipher column costs the text and nothing
  /// else. `byteaToBytes` rejects null outright and can throw on a value the
  /// driver hands over in an unexpected shape; a row is worth more than its
  /// ciphertext.
  static Uint8List? _maybeBytes(dynamic v, {int? expect}) {
    if (v == null) return null;
    try {
      return byteaToBytes(v, expect: expect);
    } catch (e) {
      // Counted, never silent. A cipher column that fails to decode looks
      // downstream EXACTLY like a plaintext-only row from an old client:
      // hydrate skips it, the shortfall counter never sees it, and the write
      // counter still says `sealed: true`. Both of the numbers step 3 is gated
      // on would report a clean fleet while ciphertext was being thrown away on
      // every fetch. The class only — the value can be anyone's message.
      cipherDecodeFailures++;
      debugPrint('[chat] body cipher column unreadable: ${e.runtimeType}');
      return null;
    }
  }

  /// Rows whose cipher column could not even be decoded into bytes this run.
  ///
  /// Read by [ChatRepository.hydrate] so the failure lands in the same
  /// ParseShortfall the decrypt failures use, rather than vanishing.
  static int cipherDecodeFailures = 0;

  /// Server-assigned monotonic order. Receipts compare THIS, never a clock:
  /// created_at is stamped by Postgres while the old read watermark was
  /// stamped by the reader's phone, so "seen" was a comparison between two
  /// different clocks and was wrong for anyone whose device time drifted.
  /// 0 means "not yet on the server" (an optimistic local message).
  final int seq;

  /// Transient: the local file rendered instantly while it uploads (optimistic
  /// media). Never comes from the DB.
  final String? localPath;
  final SendStatus sendStatus;

  Message copyWith({String? localPath, SendStatus? sendStatus}) => Message(
        id: id,
        senderId: senderId,
        createdAt: createdAt,
        seq: seq,
        body: body,
        imagePath: imagePath,
        voicePath: voicePath,
        voiceDurationMs: voiceDurationMs,
        voicePeaks: voicePeaks,
        videoPath: videoPath,
        filePath: filePath,
        fileSize: fileSize,
        replyToId: replyToId,
        kind: kind,
        deletedForEveryone: deletedForEveryone,
        deletedBy: deletedBy,
        localPath: localPath ?? this.localPath,
        sendStatus: sendStatus ?? this.sendStatus,
        albumId: albumId,
        hasThumb: hasThumb,
        bodyCipher: bodyCipher,
        bodyNonce: bodyNonce,
        bodyUndecryptable: bodyUndecryptable,
        editedAt: editedAt,
      );

  /// The result of hydration: the opened text, or the admission that it could
  /// not be opened. The ciphertext is dropped once it has been resolved —
  /// nothing downstream re-decrypts, and holding it would keep the encrypted
  /// copy alive in memory next to the plaintext for no reason.
  Message withDecrypted(String? text) => Message(
        id: id,
        senderId: senderId,
        createdAt: createdAt,
        seq: seq,
        body: text ?? body,
        imagePath: imagePath,
        voicePath: voicePath,
        voiceDurationMs: voiceDurationMs,
        voicePeaks: voicePeaks,
        videoPath: videoPath,
        filePath: filePath,
        fileSize: fileSize,
        replyToId: replyToId,
        kind: kind,
        deletedForEveryone: deletedForEveryone,
        deletedBy: deletedBy,
        localPath: localPath,
        sendStatus: sendStatus,
        albumId: albumId,
        hasThumb: hasThumb,
        // Undecryptable only when there was ciphertext, it did not open, AND no
        // plaintext survived on the row to show instead. During the dual-write
        // era `body` is still populated, so a key problem is invisible to the
        // reader — which is the entire reason dual-write exists.
        bodyUndecryptable: text == null && bodyCipher != null && body == null,
        editedAt: editedAt,
      );

  /// Adopt the authoritative server row (its created_at fixes cross-device
  /// ordering; its paths/deletions are canonical) while keeping the transient
  /// local file so an optimistic image keeps showing without a re-download.
  Message reconcileWith(Message server) => Message(
        id: id,
        senderId: server.senderId,
        createdAt: server.createdAt,
        // The server wins on everything EXCEPT losing text we already have.
        // The echo of our own send arrives without the plaintext once writes go
        // cipher-only, and a hydrated echo can still resolve to null on a
        // device mid-key-exchange — either way this used to blank the sender's
        // own bubble about a second after they sent it, on their own phone.
        body: server.body ?? body,
        imagePath: server.imagePath,
        voicePath: server.voicePath,
        voiceDurationMs: server.voiceDurationMs,
        voicePeaks: server.voicePeaks,
        videoPath: server.videoPath,
        filePath: server.filePath,
        fileSize: server.fileSize,
        replyToId: server.replyToId,
        kind: server.kind,
        deletedForEveryone: server.deletedForEveryone,
        deletedBy: server.deletedBy,
        localPath: localPath,
        // The server's seq is the whole point of reconciling. Omitting it fell
        // back to the constructor default of 0, so every optimistically-shown
        // message and everything arriving over the broadcast fast path stayed
        // at 0 forever: _maxSeq never advanced, ack_read was never called, and
        // both partners sat on a single grey tick for the entire conversation.
        // Invisible to two accounts with history (their mount-time fetch seeds
        // a non-zero _maxSeq); total for a brand-new couple, whose first
        // conversation has none.
        seq: server.seq,
        // Both are the server's to state. The optimistic bubble was built
        // before the thumbnail had finished uploading, so its own hasThumb is
        // stale by construction and would keep the tile on the original.
        albumId: server.albumId,
        hasThumb: server.hasThumb,
        bodyCipher: server.bodyCipher,
        bodyNonce: server.bodyNonce,
        // Only if the reconciled row ends up with no text at all. Keeping the
        // local plaintext above must also clear the "can't open this" state, or
        // the bubble would claim to be unreadable while showing its own text.
        bodyUndecryptable:
            server.bodyUndecryptable && (server.body ?? body) == null,
      );

  final String id;
  final String senderId;
  final String? body;
  final String? imagePath;
  final String? voicePath;

  /// How long the voice note runs, in milliseconds, or null when nobody knows.
  ///
  /// Null is a permanent state, not a transitional one: every note sent before
  /// the column existed keeps it, and so does everything from a client older
  /// than this build — the fleet is sideloaded and has no update channel. The
  /// bubble draws no label at all for those rather than inventing one.
  final int? voiceDurationMs;

  /// The recording's own loudness, one byte per bar, base64 — the shape the
  /// bubble draws instead of a decorative pattern.
  ///
  /// Null is permanent rather than transitional, for the same reason
  /// [voiceDurationMs] is: every note sent before the column existed, and
  /// everything from a client older than this build, on a fleet that is
  /// sideloaded with no update channel. Those bubbles draw a pattern derived
  /// from the message id, which is at least stable per note.
  ///
  /// **Deliberately plaintext, and it is the one exception in this file.**
  /// `body` is ciphered because it IS the message, and message_reactions has no
  /// plaintext emoji column at all. Two rules point opposite ways here — "E2EE
  /// stays, no plaintext at rest" against "minimal footprint" — and the tie is
  /// broken by the audio itself already sitting unencrypted in couple_media:
  /// enciphering a rendering hint whose subject is stored in the clear beside
  /// it buys nothing. That reasoning does not extend to the next piece of voice
  /// metadata without being asked again.
  final String? voicePeaks;
  final String? videoPath;

  /// couple_files object name. [body] carries the file's display name, so a
  /// build that predates this column still shows what was sent instead of an
  /// empty bubble — this fleet has no update channel.
  final String? filePath;
  final int? fileSize;
  final String? replyToId;
  final String kind;

  /// Which multi-select send this arrived in, or null.
  ///
  /// Null covers two permanent cases, not one transitional one: a single send,
  /// and anything from a build older than the column — this fleet is sideloaded
  /// and has no update channel, so those keep arriving indefinitely. The list
  /// falls back to grouping by sender and time whenever this is absent.
  final String? albumId;

  /// A thumbnail sibling exists for this row's media.
  ///
  /// False on everything written before the pipeline, which renders from the
  /// original exactly as it always did.
  final bool hasThumb;

  /// The thumbnail's path in [chatBucket], if there is one to read.
  String? get imageThumbPath => !hasThumb || imagePath == null
      ? null
      : Thumbnails.pathFor(MediaUrls.toPath(chatBucket, imagePath!));

  /// The poster frame's path in [privateBucket], if there is one.
  String? get videoThumbPath => !hasThumb || videoPath == null
      ? null
      : Thumbnails.pathFor(MediaUrls.toPath(privateBucket, videoPath!));

  /// A short preview of a message for quote-replies.
  String previewText() {
    if (deletedForEveryone) return 'deleted message';
    // Before the kind switch, or the default arm answers the literal 'Message'
    // for an empty body — so a reply chip would read as an ordinary short
    // message while the bubble it quotes says it cannot be opened. Two accounts
    // of one row on one screen, and the quote is the wrong one.
    if (bodyUndecryptable) return "can't open this";
    switch (kind) {
      case 'image':
        return '📷 Photo';
      case 'voice':
        return '🎙️ Voice note';
      case 'video':
        return '🎬 Video';
      case 'file':
        return '📎 ${(body ?? 'File').trim()}';
      default:
        final b = (body ?? '').trim();
        return b.isEmpty
            ? 'Message'
            : (b.length > 60 ? '${b.substring(0, 60)}…' : b);
    }
  }

  final DateTime createdAt;
  /// When the sender last changed the text, or null if never. The server
  /// sets it; `edit_message` is the only thing that writes it.
  final DateTime? editedAt;
  final bool deletedForEveryone;
  final List<String> deletedBy;

  bool isMine(String? uid) => senderId == uid;

  /// Hidden from this user (they chose "delete for me").
  bool isHiddenFor(String? uid) => uid != null && deletedBy.contains(uid);

  /// The image, as a signed URL from the cache MediaUrls warms on load.
  ///
  /// Null when not signed yet, which the bubble already renders as
  /// "unavailable" — a placeholder for one frame, rather than a network round
  /// trip inside build().
  String? get imageUrl => imagePath == null
      ? null
      : MediaUrls.cached(chatBucket, MediaUrls.toPath(chatBucket, imagePath!));

  String? get voiceUrl => voicePath == null
      ? null
      : MediaUrls.cached(chatBucket, MediaUrls.toPath(chatBucket, voicePath!));

  /// The bucket and path a small tile should paint — thumbnail if this row has
  /// one, original if it does not.
  ///
  /// A video has no paintable bytes of its own, so without a poster frame it
  /// resolves to null and the tile draws its placeholder rather than a hole.
  /// A GIF or animated WebP, which must not go through CachedNetworkImage —
  /// some cache configurations hand back a single frame and the animation dies.
  bool get isAnimated {
    final p = imagePath?.toLowerCase();
    return p != null && (p.endsWith('.gif') || p.endsWith('.webp'));
  }

  (String, String)? get _tileObject {
    if (kind == 'video') {
      final t = videoThumbPath;
      return t == null ? null : (privateBucket, t);
    }
    final t = imageThumbPath;
    if (t != null) return (chatBucket, t);
    final p = imagePath;
    return p == null ? null : (chatBucket, MediaUrls.toPath(chatBucket, p));
  }

  /// Signed URL for [_tileObject], from the cache warmMedia filled.
  String? get tileUrl {
    final o = _tileObject;
    return o == null ? null : MediaUrls.cached(o.$1, o.$2);
  }

  /// What the disk cache files a tile's bytes under. Keyed by path, never by
  /// the signed URL — that token rotates daily and would re-download the whole
  /// grid every morning.
  String? get tileCacheKey {
    final o = _tileObject;
    return o == null ? null : '${o.$1}/${o.$2}';
  }

  /// Every couple_media path this message needs signed before it can render.
  Iterable<String> get mediaPaths => [
        if (imagePath != null) MediaUrls.toPath(chatBucket, imagePath!),
        if (voicePath != null) MediaUrls.toPath(chatBucket, voicePath!),
        // The thumbnail is what the LIST paints, so it has to be in the same
        // one-request warm as the original. Signed on tap instead, every tile
        // in an album would wait on its own round trip and the grid would fill
        // in one square at a time — the thing the thumbnails were for.
        if (imageThumbPath != null) imageThumbPath!,
      ];

  /// The same, for the private bucket video lives in.
  Iterable<String> get privatePaths => [
        if (videoPath != null) MediaUrls.toPath(privateBucket, videoPath!),
        if (videoThumbPath != null) videoThumbPath!,
      ];
}

/// All chat queries. Couple-scoped via RLS on the messages table.
class ChatRepository {
  ChatRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  /// Everything the couple has sent after [afterSeq], oldest-first.
  ///
  /// postgres_changes and broadcast are both live-only: their cursor is "the
  /// moment I joined this topic". Socket drops at T0, partner sends at T1,
  /// socket reopens at T2 — the T1 insert was emitted into a socket that no
  /// longer existed and is never re-emitted. Without this the message is
  /// absent from the list, the screen and _ids: permanently invisible until
  /// the app is killed and relaunched.
  ///
  /// One page is not the gap: the caller loops while a page comes back full.
  /// [catchUpPageSize] is one number for the limit and the short-page test.
  static const catchUpPageSize = 500;

  static Future<List<Message>> fetchSince(String coupleId, int afterSeq) async {
    final res = await _c
        .from('messages')
        .select()
        .eq('couple_id', coupleId)
        .gt('seq', afterSeq)
        .order('seq', ascending: true)
        .limit(catchUpPageSize);
    // Skip a malformed row rather than aborting the whole catch-up.
    final out = await hydrate(_parseRows(res as List, 'chat catch-up'));
    await warmMedia(out);
    return out;
  }

  /// One message by id, for a quoted reply whose original is not on screen.
  ///
  /// The conversation loads the newest 300 and nothing older, so a reply to
  /// something further back than that has a quote card pointing at a message
  /// this device has never held. Tapping it has to reach the row directly or
  /// the feature dead-ends on exactly the case that motivated it.
  ///
  /// Hydrated through the same path as every other read, so a ciphered body
  /// opens here too rather than arriving as "can't open this".
  static Future<Message?> fetchById(String coupleId, String id) async {
    final res = await _c
        .from('messages')
        .select()
        .eq('couple_id', coupleId)
        .eq('id', id)
        .limit(1);
    final rows = _parseRows(res as List, 'quoted message');
    if (rows.isEmpty) return null;
    final out = await hydrate(rows);
    await warmMedia(out);
    return out.isEmpty ? null : out.first;
  }

  /// Messages newest-first (descending by server `created_at`). Pairs with a
  /// `reverse: true` ListView so the newest message sits at the bottom.
  /// The newest 300 messages.
  ///
  /// [warm] signs every media object the page will render before returning.
  /// That is one round trip per bucket and it is worth waiting for when the
  /// caller is about to render off-screen — but the chat screen holds a
  /// full-screen spinner until this future completes, so it passes false and
  /// warms after painting. Bubbles already render their "unavailable"
  /// placeholder for the frames before a path resolves (see [_tileUrl]), which
  /// is the contract that makes deferring safe.
  static Future<List<Message>> fetch(String coupleId, {bool warm = true}) async {
    final res = await _c
        .from('messages')
        .select()
        .eq('couple_id', coupleId)
        .order('created_at', ascending: false)
        .limit(300);
    // Skip a malformed row rather than blanking the whole conversation.
    final out = await hydrate(_parseRows(res as List, 'chat fetch'));
    _pageCache[coupleId] = List.unmodifiable(out);
    if (warm) await warmMedia(out);
    return out;
  }

  /// The last page this process rendered, per couple.
  ///
  /// The shell builds `bodies[bodyIndex]` rather than an IndexedStack
  /// (app_shell.dart), so moving off the Chat tab DISPOSES ChatScreen and
  /// coming back re-runs `_init` from nothing — a full-screen spinner plus a
  /// 300-row network SELECT plus 300 decrypts, on every single tap of the Chat
  /// icon, forever. There is no local message store to fall back on.
  ///
  /// Memory only, and never written to disk: these are decrypted messages in an
  /// E2EE app, and [forget] drops them on sign-out. Keyed by couple, so an
  /// account switch on the same handset cannot read the previous couple's page.
  static final Map<String, List<Message>> _pageCache = {};

  /// The cached page, or null. Callers paint it immediately and let their own
  /// [fetch] replace it — it is a head start, never the source of truth.
  static List<Message>? cachedPage(String coupleId) => _pageCache[coupleId];

  /// Drop every cached page. Sign-out and account switch.
  static void forget() => _pageCache.clear();

  /// Decode one fetched page, skipping any row whose decode throws.
  ///
  /// Counted and reported rather than silent: a conversation that parses N of
  /// M rows is a finding to explain, never a state to render as though it were
  /// complete — silently thinner history is indistinguishable from deletion.
  /// The report carries the count and the first error's class only. Row
  /// contents never go into diagnostics: this is an E2EE app, and a decode
  /// error's text can hold whatever value refused to parse.
  static List<Message> _parseRows(List<dynamic> rows, String where) {
    final out = <Message>[];
    var skipped = 0;
    Object? firstError;
    StackTrace? firstStack;
    for (final row in rows) {
      try {
        out.add(Message.fromJson(JsonUtils.asMap(row)));
      } catch (e, st) {
        skipped++;
        firstError ??= e;
        firstStack ??= st;
      }
    }
    if (skipped > 0) {
      ErrorReporter.report(
        ParseShortfall(where,
            parsed: out.length,
            of: rows.length,
            first: '${firstError.runtimeType}',),
        firstStack,
        kind: 'chat-fetch',
      );
    }
    return out;
  }

  /// Seal a message body for [rowId], or answer null if it cannot be sealed.
  ///
  /// Null is an ORDINARY answer and the caller must carry on with plaintext.
  /// `encryptString` throws whenever there is no couple key — a partner who has
  /// not published yet, a device mid key-exchange, a rewrap in flight, a pin
  /// mismatch — and `sendText` has never been able to fail for a crypto reason.
  /// It must not start now: ChatSendQueue parks a throwing send as failed and
  /// never retries it, and text bodies are deliberately not persisted, so a
  /// process kill would lose the message outright. A message that sends in the
  /// clear is worth incomparably more than one that does not send.
  ///
  /// The associated data is the row id, binding the ciphertext to its row
  /// exactly as memory_thread_repository.dart:417 does. The id therefore has to
  /// exist before the encrypt, which is why sendText mints one when the caller
  /// omits it.
  /// The associated data both halves of the message cipher must agree on.
  ///
  /// One function rather than the row id written out twice, because the two
  /// uses are 200 lines apart and a divergence would not fail loudly: it makes
  /// every message written after it permanently undecryptable, on a fleet with
  /// no update channel to correct the reader.
  @visibleForTesting
  static String bodyAd(String rowId) => rowId;

  /// Whether this insert may leave the plaintext out. The whole of step 3.
  ///
  /// Named and separate because it is the one rule that decides whether a
  /// message can end up with no readable text anywhere. BOTH conditions are
  /// required: the server has declared the fleet ready, AND this body actually
  /// sealed. A cipher-only row whose cipher never got written is a message
  /// nobody can read — not the partner, not the sender, not later. That is
  /// strictly worse than a row the server can read, so the flag alone can never
  /// cause it.
  ///
  /// Not test-only: the realtime broadcast in chat_screen carries the same
  /// sentence over a second wire and asks this same question of it.
  static bool omitPlaintext({required bool cipherOnly, required bool sealed}) =>
      cipherOnly && sealed;

  static Future<({Uint8List blob, Uint8List nonce})?> sealBody(
    String text,
    String rowId,
  ) async {
    try {
      // Join the derive that session_provider started when the partner became
      // known, instead of racing it. Without this, whether a message is sealed
      // depended on how long the user had been in the app — and the `sealed`
      // counter below would read low for reasons that have nothing to do with
      // the fleet's build level, which is the number step 3 is gated on.
      await CoupleKey.ready();
      final p =
          await CryptoCore.encryptString(text, associatedData: bodyAd(rowId));
      final nonce = base64Decode(p.nonceB64);
      final blob = packMacAndCiphertext(p);
      // Refuse the plaintext shape. An all-zero nonce or an all-zero MAC is
      // CryptoCore's old plaintext-v1 sentinel — base64 of the CLEARTEXT — and
      // storing that in a column named body_cipher would move cleartext into
      // the encrypted column and call it encrypted. The layout here is
      // mac(16)||ciphertext, so the MAC is the FIRST 16 bytes; the vault's
      // 40-byte guard is written for nonce||mac||ct and would not fire.
      if (nonce.every((b) => b == 0) ||
          blob.take(16).every((b) => b == 0)) {
        debugPrint('[chat] refusing to store an unencrypted body as cipher');
        return null;
      }
      return (blob: blob, nonce: nonce);
    } catch (e) {
      // Debug only. The failure is already recorded for release in the
      // `sealed` field of msg_insert_result — a couple with no key hits this on
      // EVERY send, and debugPrint is not stripped from a release build, so
      // leaving it unguarded writes a line to logcat per message on a handset
      // whose whole premise is that it does not write things down.
      if (kDebugMode) {
        debugPrint('[chat] body not sealed, sending plaintext: '
            '${e.runtimeType}');
      }
      return null;
    }
  }

  /// Open any ciphertext a page carries, and never lose a message doing it.
  ///
  /// Separate from [_parseRows] on purpose. That skips rows whose decode
  /// throws, which is right for a malformed row and catastrophic for a
  /// decryption failure: a device whose key is momentarily wrong would silently
  /// erase history from the screen. Here a failure costs the TEXT of one
  /// message and nothing else — the row, its timestamp, its media, its receipts
  /// and its place in the order all survive.
  ///
  /// Rows with no ciphertext are returned untouched, which is every row today
  /// and every row any old client will ever write. That fallback is permanent:
  /// the release gate fails open, so a client below min_build can always still
  /// insert plaintext.
  static Future<List<Message>> hydrate(List<Message> messages) async {
    // Drained ABOVE the ciphertext guard, not below it. A column that will not
    // decode leaves bodyCipher NULL, so the very failure this counter exists to
    // report is the one that makes `any(bodyCipher != null)` false — a page
    // where EVERY cipher column was unreadable returned here with the count
    // still sitting in the static, unreported. The counter is the number step 3
    // is gated on, so the blind spot was exactly over the case it was written
    // for.
    final undecodable = _takeDecodeFailures();
    if (!messages.any((m) => m.bodyCipher != null)) {
      _reportDecryptShortfall(
        rows: messages.length,
        failed: 0,
        undecodable: undecodable,
      );
      return messages;
    }

    // The first page of a cold start arrives before the derive finishes, and
    // withDecrypted drops the ciphertext once it has resolved — so a row that
    // failed here is not retried by anything. Wait for the key that is already
    // on its way rather than failing the whole page against a null one.
    await CoupleKey.ready();

    var failed = 0;
    Object? firstError;
    final out = <Message>[];
    for (final m in messages) {
      if (m.bodyCipher == null) {
        out.add(m);
        continue;
      }
      // Cipher without its nonce. The DB CHECK constrains the COLUMNS, not the
      // decode, so either decoder answering null on its own input produces this
      // half-formed shape. Passing it through unflagged would leave it counted
      // as an ordinary plaintext row and render blank once body is dropped.
      if (m.bodyNonce == null) {
        failed++;
        out.add(m.withDecrypted(null));
        continue;
      }
      try {
        final text = await CryptoCore.decryptString(
          unpackMacAndCiphertext(blob: m.bodyCipher!, nonce: m.bodyNonce!),
          // Through the same function the sealer used — see [bodyAd]. The row's
          // own id, matching how every other encrypted table in this app binds
          // a blob to its row (memory_thread_repository.dart:417).
          associatedData: bodyAd(m.id),
        );
        out.add(m.withDecrypted(text));
      } catch (e) {
        failed++;
        firstError ??= e;
        out.add(m.withDecrypted(null));
      }
    }
    // Folded in with the decrypt failures so there is ONE number for
    // "ciphertext this device could not use", not two with a blind spot
    // between them.
    _reportDecryptShortfall(
      rows: messages.length,
      failed: failed,
      undecodable: undecodable,
      firstError: firstError,
    );
    return out;
  }

  /// Read the parse-time decode failures and zero them in the same step.
  ///
  /// Read-and-clear rather than read-then-clear-later: every caller must own
  /// what it takes, because a count left behind is a count some unrelated page
  /// will be blamed for.
  static int _takeDecodeFailures() {
    final n = Message.cipherDecodeFailures;
    Message.cipherDecodeFailures = 0;
    return n;
  }

  /// The one place a chat-decrypt shortfall is filed, so no path can count a
  /// failure and then forget to report it.
  ///
  /// The error CLASS only: a decrypt failure's message can carry the value that
  /// refused to open, and this is an E2EE app.
  static void _reportDecryptShortfall({
    required int rows,
    required int failed,
    required int undecodable,
    Object? firstError,
  }) {
    if (failed == 0 && undecodable == 0) return;
    // The decode failures normally belong to this very batch — the same
    // fromJson pass built it — so `rows` is the honest denominator. A count
    // LARGER than the batch means a parse that no hydrate followed leaked into
    // this one (shared_media_repository parses messages and never hydrates),
    // and subtracting it from a one-row page put a negative in the report:
    // `parsed: 1 - 0 - 12`, which reads as garbage and buries the real signal.
    // Widen the denominator instead, so the sentence stays true either way.
    final of = rows < failed + undecodable ? failed + undecodable : rows;
    ErrorReporter.report(
      ParseShortfall('chat decrypt',
          parsed: of - failed - undecodable,
          of: of,
          first: firstError != null
              ? '${firstError.runtimeType}'
              : 'cipher column unreadable',),
      StackTrace.current,
      kind: 'chat-decrypt',
    );
  }

  /// Sign everything a page of messages will render — one round trip per
  /// bucket, whatever the page holds.
  ///
  /// Video is signed here too, and not on tap. Waiting for a fresh
  /// createSignedUrl before the player can even start opening is the whole of
  /// "tap-to-open media is slow": a full request/response on a phone uplink
  /// between the finger coming off the glass and anything happening.
  static Future<void> warmMedia(Iterable<Message> messages) => Future.wait([
        MediaUrls.warm(chatBucket, messages.expand((m) => m.mediaPaths)),
        MediaUrls.warm(privateBucket, messages.expand((m) => m.privatePaths)),
      ]);

  static Future<void> sendText(String coupleId, String body,
      {String? replyToId, String? id,}) async {
    final uid = SupabaseService.currentUserId;
    // Thrown, not returned. A bare return completes normally, and a normal
    // completion is ChatSendQueue's signal that the send LANDED: it deletes
    // the pending item and its persisted copy. So a send racing an auth loss
    // was recorded as delivered while the message existed nowhere at all. A
    // throw keeps the item in the queue as a retryable failure, which is what
    // it is. Same guard on every send below.
    if (uid == null) throw StateError('not signed in');
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    // Minted here when the caller omitted it (cycle_screen twice,
    // location_map_screen once). The ciphertext is bound to the row id, so the
    // id must exist BEFORE the encrypt — and sending it explicitly also gives
    // those three paths the 23505 dedupe that only the queue's sends had.
    final rowId = id ?? const Uuid().v4();
    final sealed = await sealBody(trimmed, rowId);
    final sw = Stopwatch()..start();
    try {
      // .select('seq') is here for the trace, not for the send. Acks are
      // watermarks, so the sender's half of a receipt failure can only be
      // joined to the recipient's ack through the server seq — and a bare
      // insert returns nothing, so a SUCCESSFUL send told this device nothing
      // at all. Safe to widen: messages_select_member is the same couple
      // predicate as the insert's check, so a row this call may write is a row
      // it may read back.
      final rows = await _c.from('messages').insert({
        'id': rowId,
        'couple_id': coupleId,
        'sender_id': uid,
        // The plaintext goes UNLESS the server has declared the fleet ready to
        // stop AND this particular body actually sealed.
        //
        // Both halves matter. The flag alone is not enough: if sealBody
        // answered null — no couple key, a rewrap in flight, a pin mismatch —
        // omitting the plaintext too would write a message with no readable
        // text anywhere, for anyone, including its author. That is strictly
        // worse than a message the server can read, so the client refuses it
        // regardless of what the flag says.
        //
        // ReleaseGate.chatCipherOnly is false by default and stays false on any
        // failure to read it, so the safe direction is also the resting state.
        if (!omitPlaintext(
          cipherOnly: ReleaseGate.chatCipherOnly,
          sealed: sealed != null,
        ))
          'body': trimmed,
        if (sealed != null) 'body_cipher': bytesToBytea(sealed.blob),
        if (sealed != null) 'body_nonce': bytesToBytea(sealed.nonce),
        'kind': 'text',
        if (replyToId != null) 'reply_to_id': replyToId,
      }).select('seq');
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: rowId, fields: {
        'kind': 'text',
        'body_len': trimmed.length,
        // Whether the body actually sealed. The one number that says how far
        // the rollout has got in the field, and the only way to know the fleet
        // is ready for step 3 without reading anyone's messages. A boolean —
        // never the ciphertext, never the plaintext.
        'sealed': sealed != null,
        'ok': true,
        'server_seq':
            rows.isEmpty ? null : JsonUtils.parseInt(rows.first['seq']),
        'latency_ms': sw.elapsedMilliseconds,
      },);
    } catch (e) {
      final landed = _alreadyLanded(e);
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: rowId, fields: {
        'kind': 'text',
        'body_len': trimmed.length,
        'sealed': sealed != null,
        'ok': landed,
        'dedupe': landed,
        'error_class': e.runtimeType.toString(),
        'pg_code': e is PostgrestException ? e.code : null,
        'latency_ms': sw.elapsedMilliseconds,
      },);
      if (landed) return;
      rethrow;
    }
  }

  /// Uploads an image to couple_media/<coupleId>/<rand>.<ext> and inserts a
  /// message row of kind='image'. Returns the storage path (so callers can
  /// broadcast the fast-path 'msg'), or null if the row this [id] names was
  /// already written by an earlier attempt.
  static Future<String?> sendImage(String coupleId, File file,
      {String? replyToId, String? id, String? albumId,}) async {
    final uid = SupabaseService.currentUserId;
    // Thrown, not returned — a return reads as success to the queue (sendText).
    if (uid == null) throw StateError('not signed in');

    final ext = _ext(file.path) ?? 'jpg';
    final path = '$coupleId/${_randomName('img', ext)}';
    // Started before the upload is awaited, not after: the decode runs in an
    // isolate while the original is on the wire, so the thumbnail costs the
    // send almost nothing.
    final pending = Thumbnails.forImage(file);
    await _c.storage.from(chatBucket).upload(path, file);
    final hasThumb = await _putThumb(chatBucket, path, await pending);
    final sw = Stopwatch()..start();
    try {
      await _c.from('messages').insert({
        if (id != null) 'id': id,
        'couple_id': coupleId,
        'sender_id': uid,
        'image_path': path,
        'kind': 'image',
        if (replyToId != null) 'reply_to_id': replyToId,
        if (albumId != null) 'album_id': albumId,
        'has_thumb': hasThumb,
      });
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: id, fields: {
        'kind': 'image',
        'ok': true,
        'latency_ms': sw.elapsedMilliseconds,
      },);
    } catch (e) {
      final landed = _alreadyLanded(e);
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: id, fields: {
        'kind': 'image',
        'ok': landed,
        'dedupe': landed,
        'error_class': e.runtimeType.toString(),
        'pg_code': e is PostgrestException ? e.code : null,
        'latency_ms': sw.elapsedMilliseconds,
      },);
      // Null rather than [path]: the row is already there and already names the
      // object the FIRST attempt uploaded, so broadcasting this attempt's path
      // would push the partner a path their row does not carry.
      if (landed) return null;
      rethrow;
    }
    return path;
  }

  /// Uploads a GIF/sticker to couple_media and returns a signed URL — no
  /// message row is inserted (used for flinging a GIF, which is ephemeral).
  /// Returns a SIGNED url. Was a public one, which outlived the burst it
  /// was sent for by exactly forever.
  static Future<String?> uploadGif(String coupleId, File file) async {
    final ext = _ext(file.path) ?? 'gif';
    final path = '$coupleId/${_randomName('gif', ext)}';
    await _c.storage.from(chatBucket).upload(path, file);
    return MediaUrls.sign(chatBucket, path);
  }

  /// Uploads a video to the PRIVATE couple_intimate bucket and inserts a
  /// message of kind='video'. Served via short-lived signed URLs (couple-only).
  ///
  /// [id] is the optimistic bubble's id. Without it the server minted its own
  /// and the DB echo could not be matched to the bubble already on screen, so
  /// every video the queue sent appeared twice — invisible while videos went
  /// one at a time, obvious the moment a pick of twelve does.
  static Future<void> sendVideo(String coupleId, File file,
      {String? replyToId, String? id, String? albumId,}) async {
    final uid = SupabaseService.currentUserId;
    // Thrown, not returned — a return reads as success to the queue (sendText).
    if (uid == null) throw StateError('not signed in');

    final ext = _ext(file.path) ?? 'mp4';
    final path = '$coupleId/${_randomName('vid', ext)}';
    final pending = Thumbnails.forVideo(file);
    await _c.storage.from(privateBucket).upload(path, file);
    final hasThumb = await _putThumb(privateBucket, path, await pending);
    try {
      await _c.from('messages').insert({
        if (id != null) 'id': id,
        'couple_id': coupleId,
        'sender_id': uid,
        'video_path': path,
        'kind': 'video',
        if (replyToId != null) 'reply_to_id': replyToId,
        if (albumId != null) 'album_id': albumId,
        'has_thumb': hasThumb,
      });
    } catch (e) {
      if (!_alreadyLanded(e)) rethrow;
    }
  }

  /// Upload [bytes] as the thumbnail beside [originalPath]. Answers whether the
  /// row may claim one.
  ///
  /// Every failure answers false rather than throwing. A thumbnail is an
  /// optimisation, and losing the photo because the small copy of it did not
  /// upload would be a bad trade — the row simply renders from the original,
  /// which is what every row written before this pipeline already does.
  static Future<bool> _putThumb(
      String bucket, String originalPath, Uint8List? bytes,) async {
    if (bytes == null) return false;
    try {
      await _c.storage.from(bucket).uploadBinary(
            Thumbnails.pathFor(originalPath),
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      return true;
    } catch (e) {
      debugPrint('[thumb] upload failed for $bucket: ${e.runtimeType}');
      return false;
    }
  }

  /// A signed URL for a private video. Served from the cache [warmMedia]
  /// filled when the page loaded, so opening one is usually not a round trip.
  static Future<String?> signedVideoUrl(String? path) => path == null
      ? Future.value()
      : MediaUrls.sign(privateBucket, MediaUrls.toPath(privateBucket, path));

  /// Uploads a document to couple_files and inserts a message of kind='file'.
  ///
  /// Its own bucket, not couple_media: that one's allowed_mime_types is a
  /// whitelist of images and audio, and widening it for a PDF would widen it
  /// for every photo in the conversation.
  ///
  /// [name] comes from the picker, not from the path. The document provider
  /// hands back a cached copy under a name of its own, and "what is this
  /// file called" is the only thing the bubble has to show.
  static Future<void> sendFile(String coupleId, File file, String name,
      {String? replyToId, String? id,}) async {
    final uid = SupabaseService.currentUserId;
    // Thrown, not returned — a return reads as success to the queue (sendText).
    if (uid == null) throw StateError('not signed in');

    final ext = _ext(name) ?? _ext(file.path) ?? 'bin';
    final path = '$coupleId/${_randomName('file', ext)}';
    await _c.storage.from(filesBucket).upload(path, file);
    try {
      await _c.from('messages').insert({
        if (id != null) 'id': id,
        'couple_id': coupleId,
        'sender_id': uid,
        'file_path': path,
        'file_size': await file.length(),
        // The name goes in body so an older client renders it as text rather
        // than an empty bubble it has no case for.
        'body': name,
        'kind': 'file',
        if (replyToId != null) 'reply_to_id': replyToId,
      });
    } catch (e) {
      if (!_alreadyLanded(e)) rethrow;
    }
  }

  /// A signed URL for a document, minted on demand — file bubbles render a
  /// name and a size, so unlike a photo there is nothing to pre-sign for.
  static Future<String?> signedFileUrl(String? path) => path == null
      ? Future.value()
      : MediaUrls.sign(filesBucket, MediaUrls.toPath(filesBucket, path));

  /// Uploads a voice note and inserts a message row of kind='voice'.
  ///
  /// [id] is the recording's id, and the caller must keep it the same across
  /// every attempt at the same recording. Without one the server mints a fresh
  /// uuid per call, so a retry of a send whose INSERT had actually landed —
  /// only its response was lost — wrote a second row the id dedupe could not
  /// see, and the note arrived twice on both phones.
  static Future<void> sendVoice(String coupleId, File file,
      {String? replyToId, String? id, String? peaks,}) async {
    final uid = SupabaseService.currentUserId;
    // Thrown, not returned — a return reads as sent to the input bar's retry
    // snackbar too, and the recording is the only copy of the note (sendText).
    if (uid == null) throw StateError('not signed in');

    final ext = _ext(file.path) ?? 'm4a';
    final path = '$coupleId/${_randomName('voice', ext)}';
    // Read off the local file, before the upload: the bubble has to be able to
    // say how long a note runs without downloading and decoding the audio.
    final durationMs = await m4aDurationMs(file);
    await _c.storage.from(chatBucket).upload(path, file);
    try {
      await _c.from('messages').insert({
        if (id != null) 'id': id,
        'couple_id': coupleId,
        'sender_id': uid,
        'voice_path': path,
        'kind': 'voice',
        // Omitted rather than sent as null when it could not be read, so a
        // recording this cannot measure writes the exact row it always did.
        if (durationMs != null) 'voice_duration_ms': durationMs,
        // Same omit-rather-than-null rule, plus a length the column will
        // actually accept. messages_voice_peaks_len refuses anything over 256
        // characters, and that refusal is a 23514 — which _alreadyLanded does
        // NOT treat as landed, so it rethrows, the audio is already uploaded,
        // and every retry orphans another object while failing identically.
        // A note is worth more than its waveform: drop the shape, keep the note.
        if (peaks != null && peaks.length <= VoicePeaks.maxEncodedLength)
          'voice_peaks': peaks,
        if (replyToId != null) 'reply_to_id': replyToId,
      });
    } catch (e) {
      if (!_alreadyLanded(e)) rethrow;
    }
  }

  /// Live stream of new messages for this couple (both partners' sends).
  /// [onDelete] is called on any DELETE event (e.g. clear-for-everyone) so the
  /// partner's screen can reload without processing individual row payloads.
  static RealtimeChannel subscribe(
    String coupleId,
    void Function(Message) onInsert, {
    VoidCallback? onDelete,
  }) {
    return _c
        .channel('messages:$coupleId', opts: const RealtimeChannelConfig(private: true))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) {
            final raw = payload.newRecord;
            // Presence is read off the RAW map, never by decoding it. Building
            // a Message here first meant every ciphered row was parsed twice:
            // once off the realtime payload, whose bytea encoding this app does
            // not trust, and again off the refetch. The throwaway parse still
            // incremented cipherDecodeFailures, so a row that refetched and
            // decrypted PERFECTLY was reported as `0/1 cipher column
            // unreadable` — the shortfall counter accusing the fetch path of
            // losing ciphertext it had actually opened. Observed on build 66,
            // first live run.
            if (raw['body_cipher'] == null) {
              final m = Message.fromJson(raw);
              // Report it HERE though, because a cipher column that would not
              // decode arrives looking exactly like this row — null cipher —
              // and skipping hydrate left its count in the static for whatever
              // page drained next to be blamed for.
              _reportDecryptShortfall(
                rows: 1,
                failed: 0,
                undecodable: _takeDecodeFailures(),
              );
              onInsert(m);
              return;
            }
            // A ciphered row is REFETCHED, never opened from this payload.
            // postgres_changes and PostgREST do not hand `bytea` over in the
            // same encoding, and no decoder downstream re-checks the length it
            // decoded, so a wrongly-sized nonce reached XChaCha20 and died as
            // an ArgumentError that reads like a missing key instead of a bad
            // wire. `couple_unlink` already refetches for exactly this reason
            // (app_shell.dart). A refetch that cannot be made delivers the
            // realtime row unhydrated: no worse than before, and never garbage.
            unawaited(() async {
              try {
                final fresh = await fetchById(coupleId, JsonUtils.parseString(raw['id']));
                if (fresh != null) {
                  onInsert(fresh);
                  return;
                }
              } catch (e) {
                debugPrint('[chat] live refetch failed: ${e.runtimeType}');
              }
              // Last resort, so a message is never lost to a refetch that could
              // not be made. This one DOES decode the realtime payload, so its
              // failures are DRAINED rather than filed: they are a known
              // property of that wire, not the fetch path losing ciphertext,
              // and reporting them is what made a healthy fetch look broken.
              final m = Message.fromJson(raw);
              _takeDecodeFailures();
              onInsert(m);
            }());
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (_) => onDelete?.call(),
        )
        .subscribe((status, [error]) {
      // kRtChatDebug is a compile-time false, so in the field this join status
      // went nowhere: a CHANNEL_ERROR here stops every message arriving live
      // and neither phone says anything.
      Diag.record(DiagArea.receipt, 'rt_channel_join', corr: coupleId, fields: {
        'topic_kind': 'messages',
        'status': status.name,
        'error_class': error?.runtimeType.toString(),
      },);
      // Diag is inert in shipped builds; this is the sink that leaves the
      // handset. A refused join means no live message arrives on this phone.
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        ErrorReporter.report(
          error ?? StateError('realtime messages: ${status.name}'),
          StackTrace.current,
          kind: 'realtime-subscribe',
        );
      }
      if (kRtChatDebug) {
        debugPrint('[rt] messages:$coupleId join=$status err=${error ?? ''}');
      }
    });
  }

  // ─── deletion ─────────────────────────────────────────────────

  /// "Delete for me" — hides the message for the current user only.
  static Future<void> deleteForMe(String messageId) =>
      _c.rpc<dynamic>('hide_message', params: {'p_message_id': messageId});

  /// "Delete for everyone" — sender-only; both see a "deleted" placeholder.
  static Future<void> deleteForEveryone(String messageId) => _c.rpc<dynamic>(
        'delete_message_for_everyone',
        params: {'p_message_id': messageId},
      );

  /// Edit a text message you sent. Answers the server's verdict — `ok`, or one
  /// of `not_found` `wrong_couple` `not_text` `deleted` `too_late` `too_soon`
  /// `no_cipher` `too_many` `refused` — rather than throwing, because each one
  /// is a different sentence to the user and an exception flattens them into
  /// "something went wrong".
  ///
  /// Every rule lives in `edit_message` and none of them is re-implemented
  /// here: ownership, the 30-minute window, a 3-second debounce, 60 edits an
  /// hour, and a refusal to strip the cipher off a row that had one. A client
  /// that checked these itself would be a client a modified build could talk
  /// out of them.
  ///
  /// The ciphertext is bound to the message id (`bodyAd(rowId)`), so the edit
  /// re-seals against the SAME id — sealing against a new one would write a
  /// blob no reader could open.
  static Future<String> editMessage(String messageId, String body) async {
    // A verdict, not a throw. Every other refusal here is a verdict, and the
    // five StateErrors in this file are a census of SEND paths — an edit is not
    // one, and the queue that census protects never carries edits.
    if (SupabaseService.currentUserId == null) return 'not_signed_in';
    final trimmed = body.trim();
    if (trimmed.isEmpty) return 'empty';
    final sealed = await sealBody(trimmed, messageId);
    final res = await _c.rpc<dynamic>('edit_message', params: {
      'p_message_id': messageId,
      // The same dual-write rule the insert uses. Diverging here would let an
      // edit drop the plaintext off a row whose cipher the fleet still cannot
      // read — which is the live field failure, not a hypothetical one.
      'p_body': omitPlaintext(
        cipherOnly: ReleaseGate.chatCipherOnly,
        sealed: sealed != null,
      )
          ? null
          : trimmed,
      // bytesToBytea, not the raw list: bytea crosses PostgREST in a specific
      // encoding and the insert path already settled which.
      'p_cipher': sealed == null ? null : bytesToBytea(sealed.blob),
      'p_nonce': sealed == null ? null : bytesToBytea(sealed.nonce),
    });
    return res as String? ?? 'refused';
  }

  /// The sentence for each verdict [editMessage] can answer. Copy recovered
  /// verbatim from build 52 — see docs/archive/BUILD-52-AUDIT.md.
  static String editMessageError(String verdict) {
    switch (verdict) {
      case 'not_text':
        return 'Only text messages can be edited.';
      case 'not_found':
        return 'That message is no longer there.';
      case 'deleted':
        return 'That message was deleted.';
      case 'wrong_couple':
        return 'That message belongs to a conversation you have left.';
      case 'too_many':
        return "You've edited a lot of messages this hour. Try again later.";
      case 'too_late':
        return 'That message is too old to edit.';
      case 'not_signed_in':
        return 'Sign in again to edit.';
      case 'too_soon':
        return 'That message changed while you were editing it. '
            'Have another look.';
      default:
        return "Couldn't save that edit. Check your connection and try again.";
    }
  }

  /// Hard-deletes every message in the couple's conversation for both users.
  /// The RPC derives the couple_id from auth.uid() server-side.
  static Future<void> clearConversation() =>
      _c.rpc<dynamic>('clear_conversation_everyone');

  // ─── helpers ──────────────────────────────────────────────────

  /// The row this insert was trying to write is already there — so the call has
  /// its desired end state and is a success, not a failure.
  ///
  /// An insert can land server-side and its response still be lost: the 30s
  /// TimeoutHttpClient ceiling on a bad uplink, or the socket dropping under
  /// it. The retry that follows carries the SAME client id and collides with
  /// the row the first attempt wrote. Reporting that as a failure left the
  /// sender looking at a red bubble whose retry could never go green, for a
  /// message the partner already had — and what a user does about that is
  /// retype it, which mints a new id and genuinely does send it twice.
  ///
  /// Postgres raises SQLSTATE 23505 for a unique violation and PostgREST
  /// passes that through verbatim as [PostgrestException.code]. Unambiguous on
  /// this table: `messages_pkey` on `id` is its only unique index (verified
  /// against prod 2026-08-17 — every other index there is non-unique), so 23505
  /// here has exactly one meaning.
  static bool _alreadyLanded(Object e) =>
      e is PostgrestException && e.code == '23505';

  static String? _ext(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    return path.substring(dot + 1).toLowerCase();
  }

  static String _randomName(String prefix, String ext) {
    final rng = Random();
    final hex =
        List.generate(12, (_) => rng.nextInt(16).toRadixString(16)).join();
    final ms = DateTime.now().millisecondsSinceEpoch;
    return '${prefix}_$ms$hex.$ext';
  }

  /// How long an m4a recording runs, in milliseconds, read from the file's own
  /// header. Null when it cannot be read.
  ///
  /// The recorder does not report a duration — record 7.1.0's `stop()` hands
  /// back the path and nothing else, and the only Duration in the package is
  /// the amplitude polling interval — so the choice was this or a wall clock
  /// around start/stop. A wall clock counts microphone warm-up and the
  /// encoder's closing flush as though they were audio, and on the short notes
  /// this was raised about ("2 seconds, 3 seconds") that overshoot is the whole
  /// difference between 0:02 and 0:03. The mvhd box is the length the encoder
  /// itself wrote down when it closed the file, so it is what the note plays
  /// for.
  ///
  /// Pure Dart over a few dozen bytes on purpose: this sits in the send path of
  /// the app's most-used feature, so it must not spin up a decoder, take an
  /// audio-focus lock, or be able to hang. Every failure answers null and the
  /// note sends exactly as it did before.
  ///
  /// Public so the box walk can be exercised against a real recording.
  static Future<int?> m4aDurationMs(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final moov = await _box(raf, 0, await raf.length(), 'moov');
      if (moov == null) return null;
      final mvhd = await _box(raf, moov.$1, moov.$2, 'mvhd');
      if (mvhd == null) return null;
      await raf.setPosition(mvhd.$1);
      final f = await raf.read(32);
      if (f.length < 32) return null;
      // mvhd payload: version(1) flags(3), then created/modified/timescale/
      // duration. The dates and the duration are 32-bit at version 0 and
      // 64-bit at version 1; timescale is 32-bit either way.
      final v1 = f[0] == 1;
      final timescale = _be32(f, v1 ? 20 : 12);
      final duration = v1 ? _be64(f, 24) : _be32(f, 16);
      // 0xFFFFFFFF is the container's own way of saying it does not know.
      if (timescale == 0 || duration <= 0 || duration == 0xFFFFFFFF) return null;
      return (duration * 1000 / timescale).round();
    } catch (e) {
      debugPrint('[voice] no duration from ${file.path}: ${e.runtimeType}');
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// The payload range of the first [type] box lying between [start] and [end],
  /// walking siblings. `moov` is written last in a recording — the encoder does
  /// not know the duration until it stops — so this cannot just read the head
  /// of the file.
  static Future<(int, int)?> _box(
    RandomAccessFile raf,
    int start,
    int end,
    String type,
  ) async {
    var at = start;
    while (at + 8 <= end) {
      await raf.setPosition(at);
      final head = await raf.read(8);
      if (head.length < 8) return null;
      var size = _be32(head, 0);
      var header = 8;
      if (size == 1) {
        // A 64-bit size, carried after the type, for boxes past 4 GiB.
        final big = await raf.read(8);
        if (big.length < 8) return null;
        size = _be64(big, 0);
        header = 16;
      } else if (size == 0) {
        size = end - at; // runs to the end of its parent
      }
      // A size that does not fit inside the parent means this is not the
      // structure it claims to be; walking on would be reading noise.
      if (size < header || at + size > end) return null;
      if (String.fromCharCodes(head.sublist(4, 8)) == type) {
        return (at + header, at + size);
      }
      at += size;
    }
    return null;
  }

  static int _be32(List<int> b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  static int _be64(List<int> b, int i) => (_be32(b, i) << 32) | _be32(b, i + 4);
}
