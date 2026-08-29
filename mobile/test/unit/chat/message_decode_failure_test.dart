import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// The counter step 3 is gated on, and the two ways it used to lie.
///
/// `cipherDecodeFailures` is incremented inside `Message.fromJson` when a bytea
/// column will not decode into bytes at all — bytea_output flipped to escape, a
/// truncated hex value, a driver handing over an unexpected shape. Such a row
/// arrives with `bodyCipher` NULL, which is the whole difficulty: downstream it
/// is indistinguishable from a plaintext-only row written by an old client, so
/// the counter is the only evidence that ciphertext was thrown away.
void main() {
  late List<Map<String, Object?>> rows;

  setUp(() {
    CryptoCore.clearCache();
    // resetForTest puts both seams back to real, so the stub goes on after it.
    ErrorReporter.resetForTest();
    rows = [];
    ErrorReporter.insertRow = (row) async => rows.add(row);
    Message.cipherDecodeFailures = 0;
  });

  tearDown(() => Message.cipherDecodeFailures = 0);

  Message undecodableRow(String id) => Message.fromJson({
        'id': id,
        'sender_id': 's',
        'created_at': DateTime(2026).toIso8601String(),
        'kind': 'text',
        'body': 'still here',
        // Not bytes in any encoding byteaToBytes accepts, so _maybeBytes counts
        // it and answers null — leaving a row that looks plaintext-only.
        'body_cipher': {'not': 'bytes'},
      });

  Message sealedRow(String id) => Message(
        id: id,
        senderId: 's',
        createdAt: DateTime(2026),
        // Shaped like a real blob so it reaches the real decrypt and fails
        // there, against the absent key of a cold start.
        bodyCipher: Uint8List.fromList(List.generate(48, (i) => i + 1)),
        bodyNonce: Uint8List.fromList(List.generate(24, (i) => i + 100)),
      );

  test('a page whose every cipher column failed to decode still reports',
      () async {
    // The blind spot exactly: the failure nulls bodyCipher, which falsifies the
    // "does this page carry ciphertext" guard, so hydrate used to return before
    // reading the counter it was written to drain.
    final row = undecodableRow('a');
    expect(Message.cipherDecodeFailures, 1, reason: 'the parse counted it');

    final out = await ChatRepository.hydrate([row]);
    await Future<void>.delayed(Duration.zero);

    expect(out.single.body, 'still here');
    expect(rows, hasLength(1), reason: 'silence here reports a clean fleet');
    expect(rows.single['kind'], 'chat-decrypt');
    expect(rows.single['detail'], 'chat decrypt: 0/1, first=cipher column '
        'unreadable',);
    expect(Message.cipherDecodeFailures, 0,
        reason: 'drained, or it is charged to the next page instead',);
  });

  test('failures leaked from a page that never hydrated cannot go negative',
      () async {
    // The realtime callback parses every insert but skips hydrate when there is
    // no ciphertext, and shared_media_repository parses messages and never
    // hydrates at all — so a count can outrun the page that finally drains it.
    // `messages.length - failed - undecodable` then went NEGATIVE (parsed: 1 -
    // 1 - 12) and the report read as garbage.
    Message.cipherDecodeFailures = 12;

    await ChatRepository.hydrate([sealedRow('a')]);
    await Future<void>.delayed(Duration.zero);

    expect(rows, hasLength(1));
    expect(rows.single['detail'], startsWith('chat decrypt: 0/13,'),
        reason: 'the denominator widens; parsed never goes below zero',);
  });

  test('a clean page files nothing', () async {
    await ChatRepository.hydrate([
      Message(id: 'a', senderId: 's', createdAt: DateTime(2026), body: 'hi'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(rows, isEmpty);
  });
}
