import 'package:miles/features/chat/chat_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lets screens OTHER than the chat (e.g. the rapid camera) push the chat's
/// broadcast fast-path WITHOUT creating their own `mood_burst:<coupleId>`
/// channel.
///
/// Why this exists: Supabase never dedupes channels by topic, so a second
/// `mood_burst:<id>` channel on the same socket would race the chat's live one
/// and one would go dead. The chat screen therefore registers its already-
/// subscribed channel here as [active] while it's mounted; other screens send
/// through it. When the chat isn't open, [active] is null and the sends are a
/// no-op — the partner still receives the photo via the (now-reliable) Postgres
/// insert echo, just a beat later.
class ChatBroadcastService {
  ChatBroadcastService._();

  /// The chat screen's live `mood_burst:<coupleId>` channel, or null when the
  /// chat isn't mounted. Set/cleared only by ChatScreen.
  static RealtimeChannel? active;

  /// Broadcast an already-uploaded image as the chat 'msg' fast-path so the
  /// partner's open chat renders it immediately (deduped by [id] when the DB
  /// echo lands). [imagePath] is the couple_media storage path.
  static void broadcastImage({
    required String id,
    required String senderId,
    required String imagePath,
    String? replyToId,
    bool previewGated = false,
  }) {
    active?.sendBroadcastMessage(
      event: 'msg',
      payload: imagePayload(
        id: id,
        senderId: senderId,
        imagePath: imagePath,
        replyToId: replyToId,
        previewGated: previewGated,
      ),
    );
  }

  /// The 'msg' payload, apart from the send so both halves can be tested
  /// against each other.
  ///
  /// The gate has to survive this hop, not just the database one: the partner
  /// renders from this map for the second or two before the Postgres echo
  /// lands, so a payload that dropped the flag would put a snap on their
  /// screen inline for exactly that long.
  static Map<String, dynamic> imagePayload({
    required String id,
    required String senderId,
    required String imagePath,
    String? replyToId,
    bool previewGated = false,
  }) =>
      {
        'id': id,
        'sender': senderId,
        'kind': 'image',
        'imagePath': imagePath,
        'previewGated': previewGated,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'replyToId': replyToId,
      };

  /// The receiving half of [imagePayload]. Null when the payload names no
  /// message, which the chat treats as nothing to show.
  static Message? messageFrom(Map<String, dynamic> payload) {
    final id = payload['id']?.toString();
    final sender = payload['sender']?.toString();
    if (id == null || sender == null) return null;
    final kind = payload['kind']?.toString() ?? 'text';
    return Message(
      id: id,
      senderId: sender,
      createdAt:
          DateTime.tryParse(payload['createdAt']?.toString() ?? '')?.toLocal() ??
              DateTime.now(),
      kind: kind,
      body: kind == 'text' ? payload['body']?.toString() : null,
      imagePath: kind == 'image' ? payload['imagePath']?.toString() : null,
      previewGated: payload['previewGated'] == true,
      replyToId: payload['replyToId']?.toString(),
    );
  }
}
