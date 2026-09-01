import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The unlink screen's layout and note-state laws, source-read.
///
/// The defect these pin was an overflow, and an overflow needs a real viewport
/// and a session to reproduce — neither of which a unit test has. What CAN be
/// proved from the source is the structure that made it possible: the screen
/// was `SafeArea > Padding > Column` with no scrollable anywhere and an
/// unbounded `Text(_note!)` inside it, so about 350 characters of farewell note
/// — or a 2.0 font scale with no note at all — laid the Re-link button out
/// below the bottom edge. Re-link is the ONLY cancel control in the whole
/// client (`UnlinkRepository.cancel` has one call site), so an unreachable one
/// means the couple is severed on the deadline with nothing anyone can tap.
void main() {
  final screen =
      File('lib/features/unlink/unlink_screen.dart').readAsStringSync();

  // The index of the `)` that closes the call opening at [open]. Skips line
  // comments and string literals, so a bracket or an apostrophe in the copy
  // cannot move the answer.
  int closeOf(String src, int open) {
    var depth = 0;
    var i = src.indexOf('(', open);
    while (i < src.length) {
      final c = src[i];
      if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
        i = src.indexOf('\n', i);
        if (i == -1) break;
      } else if (c == "'" || c == '"') {
        final quote = c;
        i = src.indexOf(quote, i + 1);
        if (i == -1) break;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
      i++;
    }
    fail('unbalanced parentheses from offset $open');
  }

  test('the ceremony scrolls', () {
    expect(screen.contains('SingleChildScrollView'), isTrue,
        reason: 'a Column with no viewport cannot hold a 1000-character note '
            'and a 56dp button on a 640dp phone',);
  });

  test('the stage pins its actions to the bottom in a REVERSE viewport', () {
    // The stage layout has no Expanded viewport; its guarantee is different
    // and equivalent: the action column rests bottom-pinned in a
    // `reverse: true` scroll view, so growth (a long farewell note) pushes
    // words UP into scroll and can never push a button off the screen.
    final stage = screen.indexOf('Widget _stageLayout(');
    expect(stage, greaterThan(-1), reason: 'the stage layout has gone');
    final stageEnd = screen.indexOf('List<Widget> _stageActions(');
    final body = screen.substring(stage, stageEnd);
    expect(body.contains('reverse: true'), isTrue,
        reason: 'without the reverse viewport, growth pushes the actions '
            'off-screen — the exact audit CRITICAL, restaged',);
    expect(body.contains('_stageActions(row'), isTrue);
    expect(body.contains("'Save our memories'"), isTrue,
        reason: 'the exits must ride the stage too — at every stage, law',);
  });

  test('time on the stage is the clock OBJECT, and it only wakes for the '
      'last call', () {
    // The owner's design: a small clock in the corner — scene-language, not
    // chrome. Digital digits never appear on the stage; the quiet arc is the
    // 24 hours, and the second hand exists only when five real minutes do.
    final stage = screen.indexOf('Widget _stageLayout(');
    final stageEnd = screen.indexOf('List<Widget> _stageActions(');
    final body = screen.substring(stage, stageEnd);
    expect(body.contains('DoorstepClock('), isTrue,
        reason: 'the stage lost its clock object',);
    expect(body.contains('_clock('), isFalse,
        reason: 'digital digits on the stage — time is an object here',);
    final wake = body.indexOf('lastCall: row.lastCall');
    expect(wake, greaterThan(-1),
        reason: "the clock's waking must be gated on the last call, or the "
            'second hand ticks urgency into the whole 24 hours',);
    expect(body.contains('_wait('), isFalse,
        reason: 'the stage shows no waiting counters; absence is the '
            '"not yet" and the companion script paces the wait',);
  });

  test('the calm cancel control is laid out OUTSIDE the scrolling region', () {
    // Anchored on the calm layout's own landmark comment, not the file's
    // first Expanded — the phone sheet legitimately holds an earlier one.
    final calm = screen.indexOf('The words scroll; the controls never do');
    expect(calm, greaterThan(-1), reason: 'the calm viewport landmark moved');
    final viewport = screen.indexOf('Expanded(', calm);
    expect(viewport, greaterThan(-1), reason: 'nothing absorbs the slack');
    final end = closeOf(screen, viewport);
    expect(screen.substring(viewport, end).contains('SingleChildScrollView'),
        isTrue,
        reason: 'the flexible child IS the viewport, or nothing scrolls',);

    // The CALL SITES, not the button's definition — it is a helper now,
    // shared by the held state and the last call so the two moments that
    // matter most cannot drift apart. `_relinkButton(),` is the invocation;
    // `_relinkButton() =>` is the declaration, which legitimately sits higher
    // up the file. EVERY invocation has to clear the viewport: one of the two
    // being safe is exactly the half-fix this law exists to catch.
    final calls = '_relinkButton(),'.allMatches(screen).toList();
    expect(calls, isNotEmpty, reason: 'the only cancel control has gone');
    // The stage's own call lives inside _stageActions, whose bottom-pinned
    // reverse viewport is covered by its own law above; every OTHER call must
    // clear the calm viewport.
    final actionsAt = screen.indexOf('List<Widget> _stageActions(');
    final actionsEnd = screen.indexOf('Widget _relinkButton()');
    for (final m in calls) {
      final inStageActions = m.start > actionsAt && m.start < actionsEnd;
      if (inStageActions) continue;
      expect(m.start, greaterThan(end),
          reason: 'inside the calm viewport, the way back is one long note '
              'away from being scrolled off a screen nobody can scroll '
              'back',);
    }
    // The export link dies with the same overflow, so it lives with it —
    // lastIndexOf: the calm copy; the stage carries its own, checked above.
    expect(screen.lastIndexOf("'Save our memories'"), greaterThan(end));
  });

  test('everything that can grow is inside the viewport', () {
    // Anchored on the calm layout's own landmark comment, not the file's
    // first Expanded — the phone sheet legitimately holds an earlier one.
    final calm = screen.indexOf('The words scroll; the controls never do');
    expect(calm, greaterThan(-1), reason: 'the calm viewport landmark moved');
    final viewport = screen.indexOf('Expanded(', calm);
    final end = closeOf(screen, viewport);
    final scrolled = screen.substring(viewport, end);
    expect(scrolled.contains('_noteCard(partnerName)'), isTrue,
        reason: 'the partner note is the unbounded child that started this',);
    // The borrowed quote is gone by the owner's call — the companion is the
    // only voice this ceremony needs — so the note is the one growable left.
  });

  test('the note editor cannot open over a load still in flight', () {
    // The write path used to gate on _busy alone and seed `_note ?? ''`, while
    // the read path 90 lines up gated on the load having resolved. A Save in
    // that window sent writeNote(coupleId, '') — which nulls note_cipher and
    // note_nonce before it ever asks for a key.
    expect(screen.contains('_busy || !_canEditNote'), isTrue,
        reason: '_busy alone lets Save land on an unresolved load',);
    final at = screen.indexOf('bool get _canEditNote');
    expect(at, greaterThan(-1));
    final gate = screen.substring(at, screen.indexOf(';', at));
    expect(gate.contains('_NoteLoad.pending'), isTrue,
        reason: 'a load in flight is the one state with nothing to edit over',);
  });

  test('a note that will not decrypt is still replaceable', () {
    // The first pass at the law above barred `sealed` from the gate too. That
    // reads as caution and is not: `prime` memoizes a completed TRUE, so once
    // openNote returns null — a mid-week rewrap, or any of the decrypt failures
    // already in the field — Try again can never move it, and the person being
    // left spends the whole seven days looking at a greyed button.
    final at = screen.indexOf('bool get _canEditNote');
    final gate = screen.substring(at, screen.indexOf(';', at));
    expect(gate.contains('_NoteLoad.sealed'), isFalse,
        reason: 'sealed must not be barred from the editor',);
    // …and the destructive branch is refused from exactly that state, which is
    // what made barring it look necessary in the first place.
    expect(screen.contains('sealedRewrite && text.trim().isEmpty'), isTrue,
        reason: 'a blank Save over unreadable ciphertext must not clear it',);
    expect(screen.contains("'Replace what you wrote'"), isTrue,
        reason: '"Edit" promises the old text is in the box; it is not',);
  });

  test('a note that will not open says so, on both sides', () {
    expect(screen.contains('_NoteLoad.sealed'), isTrue,
        reason: 'null meant "none", "not yet" and "cannot open" at once',);
  });

  test('the ceremony derives its own couple key', () {
    // CoupleKey.ready() joins an in-flight derive and starts none, so the note
    // was dead for anyone who reached /unlink by push without opening chat.
    expect(screen.contains('CoupleKey.prime'), isTrue);
  });

  test('a failed ceremony verb is filed, not just shown', () {
    final at = screen.indexOf('Future<bool> _run(');
    expect(at, greaterThan(-1));
    final body = screen.substring(at, screen.indexOf('void _say(', at));
    expect(body.contains('ErrorReporter.report'), isTrue,
        reason: 're-link, accept and the note all fail through here, and the '
            'field saw none of it',);
  });

  test('the accept dialog does not promise the partner a cancel they lack',
      () {
    // unlink_cancel deletes `where initiated_by = auth.uid()`; the acceptor is
    // never the initiator, so accepting is one-way for the only person who
    // ever reads this dialog.
    expect(screen.contains('Either of you'), isFalse);
  });
}
