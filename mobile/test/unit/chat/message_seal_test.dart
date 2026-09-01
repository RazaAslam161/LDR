import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// The write half of chat encryption, and its one non-negotiable property:
/// sealing may fail, sending may not.
///
/// `sendText` has never been able to fail for a crypto reason. If it starts,
/// the damage is not a missing cipher column — ChatSendQueue parks a throwing
/// send as failed and never auto-retries, and text bodies are deliberately not
/// persisted (chat_send_queue.dart:236-240), so the next process kill loses the
/// message outright. And `location_map_screen.dart:427` calls sendText bare
/// inside an async onTap with no catch, where a throw is a silent no-op.
///
/// Coverage limit, stated rather than implied: the no-key tests run with NO
/// couple key, because a unit test has no platform keystore —
/// crypto_core_test.dart documents the same limitation. The LIVE derive is
/// still untestable here, but the seal→hydrate round trip itself no longer
/// is: `CryptoCore.setSharedKeyForTest` injects a real 32-byte key past the
/// keystore, and the round-trip group below runs the actual seal and the
/// actual hydrate under it. What remains device-only is the derive chain
/// (keystore seed → X25519 → HKDF) — watch that on the two-handset run.
void main() {
  setUp(CryptoCore.clearCache);

  test('with no couple key, sealing answers null instead of throwing',
      () async {
    // The ordinary state of a cold start, and of any couple mid key-exchange.
    // A throw here is a lost message, not a missing column.
    expect(await ChatRepository.sealBody('hello', 'row-1'), isNull);
  });

  test('both halves derive associated data from one function', () {
    // Seal and open are 200 lines apart. If they ever disagree the failure is
    // silent and permanent — every message written after it is undecryptable,
    // on a fleet with no update channel to fix the reader. They must share this.
    expect(ChatRepository.bodyAd('row-1'), 'row-1');
    expect(ChatRepository.bodyAd('row-2'), isNot(ChatRepository.bodyAd('row-1')),
        reason: 'the binding must be per-row, or a blob could be replayed onto '
            'a different message',);
  });

  group('the step-3 flip', () {
    test('plaintext is kept until the server says otherwise', () {
      // The resting state, and the state of every environment where the column
      // does not exist or could not be read.
      expect(
        ChatRepository.omitPlaintext(cipherOnly: false, sealed: true),
        isFalse,
      );
    });

    test('an unsealed body keeps its plaintext EVEN when the flag is on', () {
      // The rule that stops step 3 destroying messages. Without it, a device
      // with no couple key — mid key-exchange, rewrap held, pin mismatch —
      // would write a row with no cipher AND no body: text nobody can ever
      // read, including the person who typed it.
      expect(
        ChatRepository.omitPlaintext(cipherOnly: true, sealed: false),
        isFalse,
      );
    });

    test('only a sealed body on a ready fleet drops the plaintext', () {
      expect(
        ChatRepository.omitPlaintext(cipherOnly: true, sealed: true),
        isTrue,
      );
    });

    test('the flag defaults off in the client', () {
      // Fail-safe: an unreachable gate, a paused project, or a column that does
      // not exist yet must all mean "keep writing plaintext".
      expect(ReleaseGate.chatCipherOnly, isFalse);
    });

    test('an absent column reads as off, not as on', () {
      // The fallback select omits chat_cipher_only entirely, so applyRow sees
      // no key at all. `== true` is what makes that false rather than a crash
      // or a null-cast surprise.
      ReleaseGate.applyRow({'min_build': 1, 'latest_build': 46});
      expect(ReleaseGate.chatCipherOnly, isFalse);

      ReleaseGate.applyRow(
        {'min_build': 1, 'latest_build': 46, 'chat_cipher_only': true},
      );
      expect(ReleaseGate.chatCipherOnly, isTrue);

      ReleaseGate.applyRow(
        {'min_build': 1, 'latest_build': 46, 'chat_cipher_only': null},
      );
      expect(ReleaseGate.chatCipherOnly, isFalse);
    });
  });

  test('an unsealed send still round-trips through hydrate as plaintext',
      () async {
    // The dual-write contract end to end: no key, so no cipher is produced, and
    // the message must still read back exactly as it was written.
    final sealed = await ChatRepository.sealBody('see you tonight', 'row-1');
    expect(sealed, isNull);

    final row = Message.fromJson({
      'id': 'row-1',
      'sender_id': 's',
      'created_at': DateTime(2026).toIso8601String(),
      'kind': 'text',
      // Exactly what the insert writes when sealBody answered null.
      'body': 'see you tonight',
    });
    final out = await ChatRepository.hydrate([row]);
    expect(out.single.body, 'see you tonight');
    expect(out.single.bodyUndecryptable, isFalse);
  });

  group('the round trip under a real key', () {
    // The flagship property, executed rather than pinned: the same sealBody
    // the send path calls, the same hydrate the read path calls, a real
    // 32-byte key between them. Injected past the keystore — the derive
    // chain itself stays device-only.
    setUp(() {
      // hydrate reports decrypt shortfalls; the seam keeps that report from
      // reaching for a Supabase client no unit test has.
      ErrorReporter.insertRow = (_) async {};
      CryptoCore.setSharedKeyForTest(
        List<int>.generate(32, (i) => (i * 3 + 1) % 256),
      );
    });
    tearDown(CryptoCore.clearCache);

    Message rowWith(
      String id, {
      required Uint8List blob,
      required Uint8List nonce,
    }) =>
        Message(
          id: id,
          senderId: 's',
          createdAt: DateTime(2026),
          bodyCipher: blob,
          bodyNonce: nonce,
        );

    test('sealing never throws, whatever it is handed', () async {
      // Empty, enormous, and full of the bytes that break naive codecs. None
      // of these may become an exception on the send path.
      //
      // Under the real key, because with no key injected this proved nothing:
      // encryptBytes threw on the null key before it ever saw the input and
      // sealBody's catch answered null, so isNull held identically for all
      // four and for anything else that could have been listed here.
      for (final text in <String>[
        '',
        ' ',
        'x' * 100000,
        // Escapes, not literal control characters: a raw NUL in the source
        // makes git treat this whole file as BINARY, so it commits with no
        // diff and cannot be reviewed. The STRING still carries them.
        'emoji \u{1F642} and \u0000 and \uFFFD',
      ]) {
        final sealed = await ChatRepository.sealBody(text, 'row-1');
        expect(sealed, isNotNull,
            reason: 'a present key must seal ${text.length} chars',);
        final out = await ChatRepository.hydrate(
          [rowWith('row-1', blob: sealed!.blob, nonce: sealed.nonce)],
        );
        expect(out.single.body, text,
            reason: 'the round trip must return the bytes it was handed',);
        expect(out.single.bodyUndecryptable, isFalse);
      }
    });

    test('sealed by the send path, opened by the read path', () async {
      final sealed = await ChatRepository.sealBody('sealed then opened', 'row-1');
      expect(sealed, isNotNull, reason: 'a present key must seal');

      final out = await ChatRepository.hydrate(
        [rowWith('row-1', blob: sealed!.blob, nonce: sealed.nonce)],
      );
      expect(out.single.body, 'sealed then opened');
      expect(out.single.bodyUndecryptable, isFalse);
    });

    test('the same blob replayed onto a different row refuses to open',
        () async {
      final sealed = await ChatRepository.sealBody('bound to row-1', 'row-1');
      final out = await ChatRepository.hydrate(
        [rowWith('row-2', blob: sealed!.blob, nonce: sealed.nonce)],
      );
      expect(out.single.bodyUndecryptable, isTrue,
          reason: 'the AD binds a blob to its row — a replay must fail closed, '
              "not render as the partner's message");
    });

    test('one flipped ciphertext byte refuses to open', () async {
      final sealed = await ChatRepository.sealBody('tamper me', 'row-3');
      final blob = Uint8List.fromList(sealed!.blob);
      blob[blob.length - 1] ^= 0x01;
      final out = await ChatRepository.hydrate(
        [rowWith('row-3', blob: blob, nonce: sealed.nonce)],
      );
      expect(out.single.bodyUndecryptable, isTrue);
    });

    test('a failed ring read no longer fails a row the current key opens',
        () async {
      final sealed = await ChatRepository.sealBody('ring down, key up', 'row-9');
      // Re-inject WITHOUT the cached ring. The open path then reads the
      // keystore for the ring, and in a unit process that read throws —
      // which is exactly the degrade branch under test: the keystore
      // failing must not take down a row the in-memory key opens.
      CryptoCore.setSharedKeyForTest(
        List<int>.generate(32, (i) => (i * 3 + 1) % 256),
        cacheEmptyRing: false,
      );
      final out = await ChatRepository.hydrate(
        [rowWith('row-9', blob: sealed!.blob, nonce: sealed.nonce)],
      );
      expect(out.single.body, 'ring down, key up');
      expect(out.single.bodyUndecryptable, isFalse);
    });
  });
}
