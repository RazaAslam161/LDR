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
  final bar =
      File('lib/features/chat/widgets/chat_input_bar.dart').readAsStringSync();

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

  test('the composer does not throw the text away before the verdict', () {
    // The test above passed for the whole life of the feature while the text
    // was being destroyed one layer down: _sendText cleared the field BEFORE
    // awaiting, so the composer the screen carefully held open was holding
    // nothing. Keeping edit mode open is only half the promise.
    final at = bar.indexOf('Future<void> _sendText() async {');
    expect(at, greaterThan(-1));
    final head = bar.substring(at, bar.indexOf('await widget.onSendText(', at));
    expect(head.contains('widget.editingMessage == null'), isTrue,
        reason: 'the clear must be conditional on NOT editing',);
    final clear = head.indexOf('_text.clear();');
    expect(clear, greaterThan(head.indexOf('widget.editingMessage == null')),
        reason: 'the clear still runs unconditionally on the edit path',);
  });

  // ─── the row has to reach the screen ─────────────────────────────

  test('the message channel listens for UPDATEs, not just INSERT and DELETE',
      () {
    // The whole reason an edit did nothing: `edit_message` wrote the new
    // ciphertext and answered ok, and this channel carried no UPDATE, so
    // neither handset ever heard. The bubble kept its original text.
    final at = repo.indexOf('static RealtimeChannel subscribe(');
    expect(at, greaterThan(-1));
    final body = repo.substring(at, repo.indexOf('/// Hard-deletes', at));
    expect(body.contains('PostgresChangeEvent.update'), isTrue,
        reason: 'an edited row has no way to reach either screen',);
  });

  test('a live UPDATE is refetched, never decoded off the realtime payload',
      () {
    // Same rule the INSERT branch is built on: postgres_changes and PostgREST
    // do not hand bytea over in the same encoding, and a wrongly-sized nonce
    // reaches XChaCha20 as an error that reads like a missing key.
    final at = repo.indexOf('PostgresChangeEvent.update');
    final body = repo.substring(at, at + 1600);
    expect(body.contains('fetchById('), isTrue);
    expect(body.contains('Message.fromJson('), isFalse,
        reason: 'an update that decodes the payload can replace good text with '
            'a row it could not open',);
  });

  test('an UPDATE for an unknown message is dropped, never inserted', () {
    // UPDATEs arrive for every row in the couple, including rows outside the
    // loaded page and rows this user cleared for themselves. Treating one as
    // an arrival puts an old message at the bottom of the conversation.
    final at = screen.indexOf('void _onRemoteUpdate(Message m) {');
    expect(at, greaterThan(-1));
    final body = screen.substring(at, screen.indexOf('\n  }', at));
    expect(body.contains('if (i < 0) return;'), isTrue,
        reason: 'an unknown id must fall out here',);
    expect(body.contains('_onIncoming'), isFalse,
        reason: 'the insert path would add the row as a new message',);
    expect(body.contains('_messages.insert'), isFalse);
  });

  test('the editing device shows its own edit without waiting for the wire',
      () {
    // It typed the text; it does not need to be told. Waiting on the round
    // trip left the bubble on its old text for as long as the network took,
    // and for ever whenever the channel had not joined.
    final at = screen.indexOf('Future<void> _saveEdit(');
    final ok = screen.indexOf("verdict == 'ok'", at);
    final body = screen.substring(ok, ok + 800);
    expect(body.contains('copyWith('), isTrue,
        reason: 'the ok branch leaves the list showing the old text',);
  });

  // ─── the fields that carry an edit ───────────────────────────────

  Message row(String body, {DateTime? editedAt, bool undecryptable = false}) =>
      Message(
        id: 'm1',
        senderId: 'me',
        createdAt: DateTime(2026),
        body: body,
        editedAt: editedAt,
        bodyUndecryptable: undecryptable,
      );

  test('reconciling adopts the server edited_at', () {
    // Source-text tests cannot see a dropped named argument — receipts_v2 all
    // passed while reconcileWith was losing seq the same way (message_seq_test).
    // Losing edited_at here means the authoritative row retires the very label
    // it arrived to set.
    final merged = row('before').reconcileWith(row('after', editedAt: DateTime(2026, 2)));
    expect(merged.editedAt, DateTime(2026, 2));
    expect(merged.body, 'after');
  });

  test('reconciling never un-edits a message', () {
    // Nothing clears edited_at, so a server row without it is a row that has
    // not been edited — not an instruction to forget that it was.
    final merged =
        row('after', editedAt: DateTime(2026, 2)).reconcileWith(row('after'));
    expect(merged.editedAt, DateTime(2026, 2));
  });

  test('patching in the typed text resolves the unreadable state', () {
    // A bubble reading "can't open this" is still editable, and the owner who
    // retypes it is holding the plaintext. Leaving the flag set would keep the
    // apology on screen over the sentence they just wrote.
    final patched = row('', undecryptable: true)
        .copyWith(body: 'typed', editedAt: DateTime(2026, 3));
    expect(patched.body, 'typed');
    expect(patched.bodyUndecryptable, isFalse);
    expect(patched.editedAt, DateTime(2026, 3));
  });

  test('copyWith still leaves the body alone when it is not given', () {
    final same = row('kept').copyWith(sendStatus: SendStatus.sending);
    expect(same.body, 'kept');
    expect(same.sendStatus, SendStatus.sending);
  });

  // ─── the edit has to survive a cover cycle ───────────────────────

  test('an edited row is written back to the cached page', () {
    // Only fetch() ever wrote _pageCache, so an edit lived in the screen's list
    // and nowhere else — and the disguise cover rebuilds the whole router
    // subtree on every background, repainting the PRE-EDIT text from the cache.
    // The edit had worked and the app showed the old message again anyway,
    // which is the report this whole section exists for.
    // Each window is the METHOD, closed at its own 2-space `}`. A fixed
    // character count reached past _onRemoteUpdate into the definition of
    // _patchCache itself and would have passed on the call never being made.
    for (final site in ['void _onRemoteUpdate(', 'Future<void> _saveEdit(']) {
      final at = screen.indexOf(site);
      expect(at, greaterThan(-1), reason: '$site has moved');
      final body = screen.substring(at, screen.indexOf('\n  }', at));
      expect(body.contains('_patchCache('), isTrue,
          reason: '$site changes a message without telling the cached page',);
    }
    expect(screen.contains('ChatRepository.patchCachedPage('), isTrue);
  });

  test('patching a page nobody cached is a no-op, never a crash', () {
    // The cover can rebuild the screen before any fetch has completed, so this
    // runs against an empty map on a cold open.
    expect(() => ChatRepository.patchCachedPage('never-fetched', row('x')),
        returnsNormally,);
  });

  test('the cache is not a second message store', () {
    // A message the cached page does not hold must not be ADDED to it. The
    // cache is the page fetch returned; growing it here would let it drift
    // into a half-page nothing re-derives.
    final at = repo.indexOf('static void patchCachedPage(');
    expect(at, greaterThan(-1));
    final body = repo.substring(at, repo.indexOf('\n  }', at));
    expect(body.contains('if (i < 0) return;'), isTrue,
        reason: 'an unheld message must fall out here',);
    expect(body.contains('.add('), isFalse);
  });
}
