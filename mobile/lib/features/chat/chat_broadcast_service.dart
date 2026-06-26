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
  }) {
    active?.sendBroadcastMessage(
      event: 'msg',
      payload: {
        'id': id,
        'sender': senderId,
        'kind': 'image',
        'imagePath': imagePath,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'replyToId': replyToId,
      },
    );
  }
}
