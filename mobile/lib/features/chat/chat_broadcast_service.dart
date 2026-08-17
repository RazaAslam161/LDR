import 'dart:convert';
import 'dart:typed_data';

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
  }) {
    active?.sendBroadcastMessage(
      event: 'msg',
      payload: imagePayload(
        id: id,
        senderId: senderId,
        imagePath: imagePath,
        replyToId: replyToId,
      ),
    );
  }

  /// The 'msg' payload, apart from the send so both halves can be tested
  /// against each other.
  static Map<String, dynamic> imagePayload({
    required String id,
    required String senderId,
    required String imagePath,
    String? replyToId,
  }) =>
      {
        'id': id,
        'sender': senderId,
        'kind': 'image',
        'imagePath': imagePath,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'replyToId': replyToId,
      };

  /// The receiving half of [imagePayload]. Null when the payload names no
  /// message, which the chat treats as nothing to show.
  ///
  /// This is a SECOND wire for the message text, independent of the database
  /// row, and it is the faster of the two — the partner renders from this
  /// before the Postgres echo lands. So it has to learn to carry ciphertext at
  /// the same time the column does, or encrypting the column would still leave
  /// every message crossing Supabase Realtime in the clear.
  ///
  /// `body` is still read, and permanently: this build must keep rendering
  /// messages from senders that only ever send plaintext, which is every build
  /// currently in the field.
  ///
  /// The returned message is NOT yet decrypted — [Message.bodyCipher] is set
  /// and the caller runs it through [ChatRepository.hydrate], the same pass the
  /// database rows use. One decryption implementation, not two.
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
      // base64, NOT the `\x` hex the bytea columns use — this is a JSON wire,
      // and hex would silently double the payload of every message.
      bodyCipher: kind == 'text' ? _b64(payload['cipher']) : null,
      bodyNonce: kind == 'text' ? _b64(payload['nonce']) : null,
      imagePath: kind == 'image' ? payload['imagePath']?.toString() : null,
      replyToId: payload['replyToId']?.toString(),
    );
  }

  /// A malformed key costs the ciphertext, never the message: the plaintext
  /// `body` beside it may still be perfectly renderable.
  static Uint8List? _b64(dynamic v) {
    if (v == null) return null;
    try {
      return base64Decode(v.toString());
    } catch (_) {
      return null;
    }
  }
}
