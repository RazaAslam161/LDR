import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// The read half of chat encryption, and specifically the promise that it
/// cannot cost anyone a message.
///
/// `_parseRows` already drops a row whose decode throws — right for a malformed
/// row, catastrophic for a decryption failure, because a device whose key is
/// momentarily wrong would silently erase history from the screen while the
/// correct plaintext sat in `body` on the same row. So decryption is a separate
/// pass, and these pin the properties that separation exists to guarantee.
///
/// Every test here runs with NO couple key derived, which is exactly the state
/// of a cold start (bindAccount clears it) and of any device mid key-exchange.
/// `decryptString` therefore throws, which is the failure path under test.
void main() {
  setUp(() {
    CryptoCore.clearCache();
    ErrorReporter.resetForTest();
  });

  Message plain(String id, String? body) =>
      Message(id: id, senderId: 's', createdAt: DateTime(2026), body: body);

  Message sealed(String id, {String? body}) => Message(
        id: id,
        senderId: 's',
        createdAt: DateTime(2026),
        body: body,
        // Shaped like a real blob — 16-byte MAC then ciphertext, 24-byte nonce
        // — so it reaches the real decrypt path and fails there for the real
        // reason, rather than being rejected as malformed on the way in.
        bodyCipher: Uint8List.fromList(List.generate(48, (i) => i + 1)),
        bodyNonce: Uint8List.fromList(List.generate(24, (i) => i + 100)),
      );

  test('a page with no ciphertext is returned untouched', () async {
    // Every row in the database today, and every row any already-installed
    // client will ever write.
    final input = [plain('a', 'hello'), plain('b', null)];
    final out = await ChatRepository.hydrate(input);
    expect(identical(out, input), isTrue,
        reason: 'the no-cipher fast path must not rebuild the list',);
  });

  test('a failed decrypt never loses a message and never reorders one',
      () async {
    final out = await ChatRepository.hydrate(
      [sealed('a'), plain('b', 'hi'), sealed('c')],
    );
    expect(out.length, 3);
    expect(out.map((m) => m.id).toList(), ['a', 'b', 'c']);
  });

  test('plaintext beside unopenable ciphertext still renders', () async {
    // The dual-write era: the row carries both. A key problem must be invisible
    // to the reader, which is the entire reason dual-write exists.
    final out = await ChatRepository.hydrate([sealed('a', body: 'hello')]);
    expect(out.single.body, 'hello');
    expect(out.single.bodyUndecryptable, isFalse,
        reason: 'there is text to show, so nothing is unopenable',);
  });

  test('ciphertext with no plaintext is flagged, not silently blank', () async {
    // After the flip. An empty bubble is indistinguishable from a deleted
    // message and from a bug, so the UI has to be able to tell the difference.
    final out = await ChatRepository.hydrate([sealed('a')]);
    expect(out.single.body, isNull);
    expect(out.single.bodyUndecryptable, isTrue);
  });

  test('cipher without its nonce is flagged, not passed through', () async {
    // The DB CHECK constrains the COLUMNS, not the decode: either decoder can
    // answer null on its own input, so a nonce that fails to parse while the
    // cipher parses fine lands here half-formed. Passing it through would count
    // it as an ordinary plaintext row and render it blank once body is dropped.
    final half = Message(
      id: 'a',
      senderId: 's',
      createdAt: DateTime(2026),
      bodyCipher: Uint8List.fromList(List.generate(48, (i) => i + 1)),
    );
    final out = await ChatRepository.hydrate([half]);
    expect(out.length, 1);
    expect(out.single.bodyUndecryptable, isTrue);
  });

  test('an unreadable cipher column is counted, not silently dropped', () {
    // Downstream a failed bytea decode looks EXACTLY like a plaintext-only row
    // from an old client, so without this counter both of the numbers the
    // rollout is gated on would report a clean fleet while ciphertext was being
    // thrown away on every fetch.
    Message.cipherDecodeFailures = 0;
    Message.fromJson({
      'id': 'a',
      'sender_id': 's',
      'created_at': DateTime(2026).toIso8601String(),
      'kind': 'text',
      'body_cipher': {'not': 'bytes'},
    });
    expect(Message.cipherDecodeFailures, 1);
    Message.cipherDecodeFailures = 0;
  });

  test('a malformed cipher column costs the text, not the row', () {
    // fromJson is SYNCHRONOUS and feeds _parseRows, which drops anything that
    // throws. A junk bytea value must therefore never throw here.
    final m = Message.fromJson({
      'id': 'a',
      'sender_id': 's',
      'created_at': DateTime(2026).toIso8601String(),
      'kind': 'text',
      'body': 'still here',
      'body_cipher': {'not': 'bytes'},
      'body_nonce': 42,
    });
    expect(m.body, 'still here');
    expect(m.bodyCipher, isNull);
  });

  test('the server echo cannot blank text we already have', () {
    // reconcileWith takes the server's row wholesale. Once writes go
    // cipher-only the echo of our OWN send arrives with body == null, and this
    // used to blank the sender's bubble a second after they sent it.
    final local = plain('a', 'typed on this phone');
    final echo = Message(
      id: 'a',
      senderId: 's',
      createdAt: DateTime(2026),
      seq: 7,
    );
    final merged = local.reconcileWith(echo);
    expect(merged.body, 'typed on this phone');
    expect(merged.seq, 7, reason: 'the server still wins on everything else');
    expect(merged.bodyUndecryptable, isFalse);
  });

  test('the broadcast wire carries base64 ciphertext, not bytea hex', () {
    final cipher = Uint8List.fromList([0, 255, 16, 32]);
    final m = ChatBroadcastService.messageFrom({
      'id': 'a',
      'sender': 's',
      'kind': 'text',
      'body': 'fallback',
      'cipher': base64Encode(cipher),
      'nonce': base64Encode(Uint8List(24)),
    });
    expect(m, isNotNull);
    expect(m!.bodyCipher, cipher);
    expect(m.body, 'fallback',
        reason: 'the plaintext key is still read, and permanently — every '
            'sender in the field today only sends that one',);
  });

  test('the sender encodes that wire the way messageFrom reads it', () {
    // The test above feeds itself base64, so it pins the DECODER and nothing
    // else — its title is a claim about the producer. The producer is an
    // inline map inside an unawaited closure in a StatefulWidget State, never
    // extracted the way imagePayload and broadcastPayload were, so it cannot
    // be called from here at all. Read from source instead: a sender switched
    // to the `\x` hex the bytea columns use would leave every test in this
    // file green while every realtime message silently lost its ciphertext
    // and fell back to plaintext on the faster of the two wires.
    //
    // Both homes that literal can have — the screen where it is written
    // inline today, and the service its siblings were extracted into — so
    // extracting it does not read here as a deletion.
    final src = [
      'lib/features/chat/chat_screen.dart',
      'lib/features/chat/chat_broadcast_service.dart',
    ].map((p) => File(p).readAsStringSync()).join('\n');
    expect(src, contains("'cipher': base64Encode("),
        reason: 'the sender must name the encoder messageFrom decodes with; '
            'the `\\x` hex of the bytea columns decodes to nothing here',);
    expect(src, contains("'nonce': base64Encode("),
        reason: 'the nonce rides the same wire under the same rule',);
  });

  test('a garbage broadcast cipher does not cost the message', () {
    final m = ChatBroadcastService.messageFrom({
      'id': 'a',
      'sender': 's',
      'kind': 'text',
      'body': 'fallback',
      'cipher': 'not base64 !!!',
    });
    expect(m, isNotNull);
    expect(m!.bodyCipher, isNull);
    expect(m.body, 'fallback');
  });
}
