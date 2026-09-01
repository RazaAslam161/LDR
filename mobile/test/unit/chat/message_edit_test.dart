import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// Message editing, recovered from build 52 (docs/archive/BUILD-52-AUDIT.md).
///
/// The backend was already live — `edit_message` returns a VERDICT rather than
/// throwing, and every rule (ownership, the 30-minute window, the 3-second
/// debounce, 60/hour, refusing to strip a cipher) lives there. So the thing
/// worth testing on this side is that no verdict falls through unnamed, and
/// that the client never re-implements a rule it does not own.
void main() {
  final repo = File('lib/features/chat/chat_repository.dart').readAsStringSync();
  final screen =
      File('lib/features/chat/chat_screen.dart').readAsStringSync();

  test('every verdict edit_message can return has its own sentence', () {
    // Taken from the deployed function body, not invented: these are the exact
    // strings `edit_message` returns.
    const verdicts = [
      'not_found',
      'wrong_couple',
      'not_text',
      'deleted',
      'too_late',
      'too_soon',
      'no_cipher',
      'too_many',
      'refused',
      'not_signed_in',
    ];
    final seen = <String>{};
    for (final v in verdicts) {
      final msg = ChatRepository.editMessageError(v);
      expect(msg, isNotEmpty, reason: '$v has no sentence');
      expect(msg.endsWith('.'), isTrue, reason: '$v is not a sentence');
      seen.add(msg);
    }
    // A switch that answered the same shrug for everything would pass the
    // check above and tell the user nothing. Most verdicts are distinct
    // failures and must read differently.
    expect(seen.length, greaterThanOrEqualTo(7),
        reason: 'verdicts are collapsing into one generic message: $seen');
  });

  test('an unknown verdict still gets a sentence rather than crashing', () {
    // The server can grow a verdict this build has never heard of. That must
    // degrade to a sentence, not to an empty snackbar or a throw.
    expect(ChatRepository.editMessageError('a_verdict_from_the_future'),
        isNotEmpty,);
  });

  /// Comments stripped, because a rule NAMED in prose is not a rule
  /// IMPLEMENTED — the first version of this test matched its own doc comment.
  String code(String src) => src
      .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '')
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');

  test('the edit window is a courtesy, never the authority', () {
    // The client mirrors the 30 minutes ONLY to avoid offering a doomed
    // button. If this ever becomes the thing that decides, a clock-skewed
    // phone starts refusing edits the server would have accepted.
    expect(screen.contains('_editWindow'), isTrue);
    expect(
      code(screen).contains('too_late'),
      isFalse,
      reason: 'the screen is deciding lateness itself; that verdict is the '
          "server's to give",
    );
  });

  test('the client does not re-implement the rate limit or the debounce', () {
    for (final rule in ['too_many', 'Duration(seconds: 3)', 'edited_at >']) {
      expect(screen.contains(rule), isFalse,
          reason: 'a rule the server owns is being duplicated client-side: '
              '$rule',);
    }
  });

  test('the edit re-seals against the SAME message id', () {
    // Ciphertext is bound to the row id via bodyAd(rowId). Sealing an edit
    // against a fresh id writes a blob no reader can ever open — a silent,
    // permanent loss of that message's text.
    final at = repo.indexOf('static Future<String> editMessage(');
    expect(at, greaterThan(-1));
    final body = repo.substring(at, at + 1600);
    expect(body.contains('sealBody(trimmed, messageId)'), isTrue,
        reason: 'the edit must seal against the message id it is editing',);
    expect(body.contains('Uuid()'), isFalse,
        reason: 'an edit that mints a new id cannot be decrypted',);
  });

  test('the edit uses the same plaintext dual-write rule as the send', () {
    // Diverging here lets an edit drop the plaintext off a row whose cipher
    // the fleet still cannot read — which is a live field failure, not a
    // hypothetical one, while chat_cipher_only stays false.
    final at = repo.indexOf('static Future<String> editMessage(');
    final body = repo.substring(at, at + 1600);
    expect(body.contains('omitPlaintext('), isTrue);
    expect(body.contains('ReleaseGate.chatCipherOnly'), isTrue);
  });

  test('bytea crosses the wire through the encoder the insert settled on', () {
    final at = repo.indexOf('static Future<String> editMessage(');
    final body = repo.substring(at, at + 1600);
    expect(body.contains('bytesToBytea('), isTrue,
        reason: 'raw bytes are not what PostgREST expects for bytea',);
  });

  test('a refused edit keeps the composer open, holding the typed text', () {
    // Dropping out of edit mode on a refusal throws away the edit as well as
    // the message — the user retypes it, or loses it. The check is on the
    // REFUSAL TAIL specifically: there are legitimate clears before it (an
    // unchanged body, and the ok branch), and an earlier version of this test
    // caught one of those and called it a bug.
    final at = screen.indexOf('Future<void> _saveEdit(');
    expect(at, greaterThan(-1));
    final snack = screen.indexOf('editMessageError', at);
    expect(snack, greaterThan(-1), reason: 'the refusal must be surfaced');
    final tail = screen.substring(at, snack);
    expect(tail.contains("verdict == 'ok'"), isTrue,
        reason: 'the ok branch must return before the refusal is shown',);
    // Everything from the snackbar to the end of the method: no clear there.
    final after = screen.substring(snack, snack + 400);
    expect(after.contains('_editingMessage = null'), isFalse,
        reason: 'a refusal is clearing edit mode, which discards the text the '
            'user just typed',);
  });
}
