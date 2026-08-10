import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


/// Flip to true to log realtime channel-join status to the console (for the
/// 2-device subscription-health test). Compile-time const → dead-code-eliminated
/// in release when false.
const bool kRtChatDebug = false;

/// A single chat message between the two partners.
///
/// [kind] is one of: 'text', 'image', 'voice', 'video'.
/// - text: [body] holds the message
/// - image: [imagePath] is the storage path; the public URL is derived
/// - voice: [voicePath] is the storage path; client plays it back
/// - video: [videoPath] is in the PRIVATE couple_intimate bucket (signed URL)
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
    this.videoPath,
    this.replyToId,
    this.kind = 'text',
    this.deletedForEveryone = false,
    this.deletedBy = const [],
    this.localPath,
    this.sendStatus = SendStatus.sent,
    this.seq = 0,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: JsonUtils.parseString(j['id']),
        senderId: JsonUtils.parseString(j['sender_id']),
        body: JsonUtils.parseStringOrNull(j['body']),
        imagePath: JsonUtils.parseStringOrNull(j['image_path']),
        voicePath: JsonUtils.parseStringOrNull(j['voice_path']),
        videoPath: JsonUtils.parseStringOrNull(j['video_path']),
        replyToId: JsonUtils.parseStringOrNull(j['reply_to_id']),
        kind: JsonUtils.parseString(j['kind'], fallback: 'text'),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
        seq: JsonUtils.parseInt(j['seq']),
        deletedForEveryone: JsonUtils.parseBool(j['deleted_for_everyone']),
        deletedBy: j['deleted_by'] is List
            ? (j['deleted_by'] as List).map((e) => e.toString()).toList()
            : const [],
      );

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
        videoPath: videoPath,
        replyToId: replyToId,
        kind: kind,
        deletedForEveryone: deletedForEveryone,
        deletedBy: deletedBy,
        localPath: localPath ?? this.localPath,
        sendStatus: sendStatus ?? this.sendStatus,
      );

  /// Adopt the authoritative server row (its created_at fixes cross-device
  /// ordering; its paths/deletions are canonical) while keeping the transient
  /// local file so an optimistic image keeps showing without a re-download.
  Message reconcileWith(Message server) => Message(
        id: id,
        senderId: server.senderId,
        createdAt: server.createdAt,
        body: server.body,
        imagePath: server.imagePath,
        voicePath: server.voicePath,
        videoPath: server.videoPath,
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
      );

  final String id;
  final String senderId;
  final String? body;
  final String? imagePath;
  final String? voicePath;
  final String? videoPath;
  final String? replyToId;
  final String kind;

  /// A short preview of a message for quote-replies.
  String previewText() {
    if (deletedForEveryone) return 'deleted message';
    switch (kind) {
      case 'image':
        return '📷 Photo';
      case 'voice':
        return '🎙️ Voice note';
      case 'video':
        return '🎬 Video';
      default:
        final b = (body ?? '').trim();
        return b.isEmpty
            ? 'Message'
            : (b.length > 60 ? '${b.substring(0, 60)}…' : b);
    }
  }

  final DateTime createdAt;
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

  /// Every storage path this message needs signed before it can render.
  Iterable<String> get mediaPaths => [
        if (imagePath != null) MediaUrls.toPath(chatBucket, imagePath!),
        if (voicePath != null) MediaUrls.toPath(chatBucket, voicePath!),
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
  static Future<List<Message>> fetchSince(String coupleId, int afterSeq) async {
    final res = await _c
        .from('messages')
        .select()
        .eq('couple_id', coupleId)
        .gt('seq', afterSeq)
        .order('seq', ascending: true)
        .limit(500);
    final out = <Message>[];
    for (final row in (res as List)) {
      try {
        out.add(Message.fromJson(JsonUtils.asMap(row)));
      } catch (_) {
        // Skip a malformed row rather than aborting the whole catch-up.
      }
    }
    await MediaUrls.warm(chatBucket, out.expand((m) => m.mediaPaths));
    return out;
  }

  /// Messages newest-first (descending by server `created_at`). Pairs with a
  /// `reverse: true` ListView so the newest message sits at the bottom.
  static Future<List<Message>> fetch(String coupleId) async {
    final res = await _c
        .from('messages')
        .select()
        .eq('couple_id', coupleId)
        .order('created_at', ascending: false)
        .limit(300);
    final out = <Message>[];
    for (final row in (res as List)) {
      try {
        out.add(Message.fromJson(JsonUtils.asMap(row)));
      } catch (_) {
        // Skip a malformed row rather than blanking the whole conversation.
      }
    }
    await MediaUrls.warm(chatBucket, out.expand((m) => m.mediaPaths));
    return out;
  }

  static Future<void> sendText(String coupleId, String body,
      {String? replyToId, String? id,}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
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
        if (id != null) 'id': id,
        'couple_id': coupleId,
        'sender_id': uid,
        'body': trimmed,
        'kind': 'text',
        if (replyToId != null) 'reply_to_id': replyToId,
      }).select('seq');
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: id, fields: {
        'kind': 'text',
        'body_len': trimmed.length,
        'ok': true,
        'server_seq':
            rows.isEmpty ? null : JsonUtils.parseInt(rows.first['seq']),
        'latency_ms': sw.elapsedMilliseconds,
      },);
    } catch (e) {
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: id, fields: {
        'kind': 'text',
        'body_len': trimmed.length,
        'ok': false,
        'error_class': e.runtimeType.toString(),
        'pg_code': e is PostgrestException ? e.code : null,
        'latency_ms': sw.elapsedMilliseconds,
      },);
      rethrow;
    }
  }

  /// Uploads an image to couple_media/<coupleId>/<rand>.<ext> and inserts a
  /// message row of kind='image'. Returns the storage path (so callers can
  /// broadcast the fast-path 'msg'), or null if there's no signed-in user.
  static Future<String?> sendImage(String coupleId, File file,
      {String? replyToId, String? id,}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;

    final ext = _ext(file.path) ?? 'jpg';
    final path = '$coupleId/${_randomName('img', ext)}';
    await _c.storage.from(chatBucket).upload(path, file);
    final sw = Stopwatch()..start();
    try {
      await _c.from('messages').insert({
        if (id != null) 'id': id,
        'couple_id': coupleId,
        'sender_id': uid,
        'image_path': path,
        'kind': 'image',
        if (replyToId != null) 'reply_to_id': replyToId,
      });
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: id, fields: {
        'kind': 'image',
        'ok': true,
        'latency_ms': sw.elapsedMilliseconds,
      },);
    } catch (e) {
      Diag.record(DiagArea.receipt, 'msg_insert_result', corr: id, fields: {
        'kind': 'image',
        'ok': false,
        'error_class': e.runtimeType.toString(),
        'pg_code': e is PostgrestException ? e.code : null,
        'latency_ms': sw.elapsedMilliseconds,
      },);
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
  static Future<void> sendVideo(String coupleId, File file,
      {String? replyToId,}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;

    final ext = _ext(file.path) ?? 'mp4';
    final path = '$coupleId/${_randomName('vid', ext)}';
    await _c.storage.from('couple_intimate').upload(path, file);
    await _c.from('messages').insert({
      'couple_id': coupleId,
      'sender_id': uid,
      'video_path': path,
      'kind': 'video',
      if (replyToId != null) 'reply_to_id': replyToId,
    });
  }

  /// A short-lived signed URL for a private video (couple_intimate bucket).
  static Future<String?> signedVideoUrl(String? path) async {
    if (path == null) return null;
    try {
      return await _c.storage
          .from('couple_intimate')
          .createSignedUrl(path, 60 * 60);
    } catch (_) {
      return null;
    }
  }

  /// Uploads a voice note and inserts a message row of kind='voice'.
  static Future<void> sendVoice(String coupleId, File file,
      {String? replyToId,}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;

    final ext = _ext(file.path) ?? 'm4a';
    final path = '$coupleId/${_randomName('voice', ext)}';
    await _c.storage.from(chatBucket).upload(path, file);
    await _c.from('messages').insert({
      'couple_id': coupleId,
      'sender_id': uid,
      'voice_path': path,
      'kind': 'voice',
      if (replyToId != null) 'reply_to_id': replyToId,
    });
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
        .channel('messages:$coupleId', opts: RealtimeChannelConfig(private: true))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) => onInsert(Message.fromJson(payload.newRecord)),
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

  /// Hard-deletes every message in the couple's conversation for both users.
  /// The RPC derives the couple_id from auth.uid() server-side.
  static Future<void> clearConversation() =>
      _c.rpc<dynamic>('clear_conversation_everyone');

  // ─── helpers ──────────────────────────────────────────────────

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
}
