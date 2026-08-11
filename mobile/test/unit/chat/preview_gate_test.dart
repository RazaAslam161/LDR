import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// The gate is one bit that has to survive three hops — the insert, the
/// Postgres echo, and the broadcast fast path — and losing it on any of them
/// puts an intimate photo on screen inline. That failure is invisible in
/// review and invisible in a screenshot: it looks exactly like a photo that was
/// never meant to be gated.
void main() {
  Map<String, dynamic> row({bool? gated}) => {
        'id': 'm1',
        'sender_id': 'me',
        'created_at': DateTime(2026).toIso8601String(),
        'kind': 'image',
        'image_path': 'couple-1/img_secret.jpg',
        if (gated != null) 'preview_gated': gated,
      };

  test('fromJson carries the gate off the server row', () {
    expect(Message.fromJson(row(gated: true)).previewGated, isTrue);
  });

  test('a row without the column reads as un-gated', () {
    // Everything sent before this feature existed, and every gallery pick
    // after it: the column defaults to false server-side and the client must
    // agree, or old photos would silently stop rendering inline.
    expect(Message.fromJson(row()).previewGated, isFalse);
    expect(Message.fromJson(row(gated: false)).previewGated, isFalse);
  });

  test('the gate survives a send-status transition', () {
    // copyWith runs on every upload tick. Dropping the flag here would show
    // the sender their own snap inline the moment it finished uploading.
    final m = Message.fromJson(row(gated: true))
        .copyWith(sendStatus: SendStatus.sent);
    expect(m.previewGated, isTrue);
  });

  test('reconciling with the server row takes the server gate', () {
    final optimistic = Message(
      id: 'm1',
      senderId: 'me',
      createdAt: DateTime(2026),
      kind: 'image',
      previewGated: true,
      localPath: '/tmp/snap.jpg',
      sendStatus: SendStatus.sending,
    );
    expect(optimistic.reconcileWith(Message.fromJson(row(gated: true)))
        .previewGated, isTrue,);
  });

  test('the broadcast fast path round-trips the gate', () {
    // The partner renders from this payload for the second or two before the
    // Postgres echo lands. A payload that dropped the flag would show the snap
    // inline for exactly that long, then quietly replace it with a placeholder.
    final payload = ChatBroadcastService.imagePayload(
      id: 'm1',
      senderId: 'me',
      imagePath: 'couple-1/img_secret.jpg',
      previewGated: true,
    );
    final m = ChatBroadcastService.messageFrom(payload)!;
    expect(m.previewGated, isTrue);
    expect(m.imagePath, 'couple-1/img_secret.jpg');
    expect(m.kind, 'image');
  });

  test('a gallery photo broadcasts un-gated', () {
    final payload = ChatBroadcastService.imagePayload(
      id: 'm2',
      senderId: 'me',
      imagePath: 'couple-1/img_picked.jpg',
    );
    expect(ChatBroadcastService.messageFrom(payload)!.previewGated, isFalse);
  });

  test('a payload naming no message yields nothing to render', () {
    expect(ChatBroadcastService.messageFrom({'kind': 'image'}), isNull);
  });
}
