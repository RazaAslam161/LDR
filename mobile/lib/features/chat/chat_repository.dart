import 'dart:io';
import 'dart:math' show Random;

import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A single chat message between the two partners.
///
/// [kind] is one of: 'text', 'image', 'voice', 'video'.
/// - text: [body] holds the message
/// - image: [imagePath] is the storage path; the public URL is derived
/// - voice: [voicePath] is the storage path; client plays it back
/// - video: [videoPath] is in the PRIVATE couple_intimate bucket (signed URL)
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
        deletedForEveryone: JsonUtils.parseBool(j['deleted_for_everyone']),
        deletedBy: j['deleted_by'] is List
            ? (j['deleted_by'] as List).map((e) => e.toString()).toList()
            : const [],
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

  /// Public URL for the image (Supabase Storage serves couple_media publicly).
  String? get imageUrl {
    if (imagePath == null) return null;
    return SupabaseService.client.storage
        .from('couple_media')
        .getPublicUrl(imagePath!);
  }

  /// Public URL for the voice note.
  String? get voiceUrl {
    if (voicePath == null) return null;
    return SupabaseService.client.storage
        .from('couple_media')
        .getPublicUrl(voicePath!);
  }
}

/// All chat queries. Couple-scoped via RLS on the messages table.
class ChatRepository {
  ChatRepository._();

  static SupabaseClient get _c => SupabaseService.client;

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
    return out;
  }

  static Future<void> sendText(String coupleId, String body,
      {String? replyToId}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    await _c.from('messages').insert({
      'couple_id': coupleId,
      'sender_id': uid,
      'body': trimmed,
      'kind': 'text',
      if (replyToId != null) 'reply_to_id': replyToId,
    });
  }

  /// Uploads an image to couple_media/<coupleId>/<rand>.<ext> and inserts a
  /// message row of kind='image'.
  static Future<void> sendImage(String coupleId, File file,
      {String? replyToId}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;

    final ext = _ext(file.path) ?? 'jpg';
    final path = '$coupleId/${_randomName('img', ext)}';
    await _c.storage.from('couple_media').upload(path, file);
    await _c.from('messages').insert({
      'couple_id': coupleId,
      'sender_id': uid,
      'image_path': path,
      'kind': 'image',
      if (replyToId != null) 'reply_to_id': replyToId,
    });
  }

  /// Uploads a video to the PRIVATE couple_intimate bucket and inserts a
  /// message of kind='video'. Served via short-lived signed URLs (couple-only).
  static Future<void> sendVideo(String coupleId, File file,
      {String? replyToId}) async {
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
      {String? replyToId}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;

    final ext = _ext(file.path) ?? 'm4a';
    final path = '$coupleId/${_randomName('voice', ext)}';
    await _c.storage.from('couple_media').upload(path, file);
    await _c.from('messages').insert({
      'couple_id': coupleId,
      'sender_id': uid,
      'voice_path': path,
      'kind': 'voice',
      if (replyToId != null) 'reply_to_id': replyToId,
    });
  }

  /// Live stream of new messages for this couple (both partners' sends).
  static RealtimeChannel subscribe(
    String coupleId,
    void Function(Message) onInsert,
  ) {
    return _c
        .channel('messages:$coupleId')
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
        .subscribe();
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

  /// Clears the whole conversation for the current user only.
  static Future<void> clearConversation() =>
      _c.rpc<dynamic>('clear_conversation');

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
