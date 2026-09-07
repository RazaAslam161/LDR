import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Wiring facts, and only wiring facts.
///
/// The rules themselves — what can be picked, what a failed batch does, when
/// "delete for everyone" may be offered — are behaviour, and live in
/// chat_selection_test.dart where they are executed rather than grepped. An
/// earlier version of this file asserted those rules as substrings and passed
/// against a build where bulk delete deleted nothing at all.
///
/// What is left here cannot be tested any other way: it is which callback the
/// screen hands to which widget, and booting the whole chat to observe it
/// costs more than it proves.
void main() {
  final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();

  String fn(String name) {
    final at = chat.indexOf(name);
    expect(at, greaterThan(-1), reason: '$name should exist');
    return chat
        .substring(at, chat.indexOf('\n  }', at))
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
  }

  group('the sweep button obeys the selection', () {
    test('it routes through the selection, not straight to clear-all', () {
      // The whole point: one button, two meanings. Wired directly to
      // _clearConversation it can only ever mean "wipe everything".
      expect(chat, contains('onClearConversation: _clearOrDeleteSelected'));
      expect(chat.contains('onClearConversation: _clearConversation'), isFalse,
          reason: 'that wiring is what deleted the whole chat regardless',);
    });

    test('clearing everything is reachable only with nothing selected', () {
      final body = fn('Future<void> _clearOrDeleteSelected()');
      expect(body, contains('if (_selecting)'));
      expect(body.indexOf('_confirmDeleteSelected'),
          lessThan(body.indexOf('_clearConversation')),
          reason: 'the selection branch has to return before the clear-all',);
    });
  });

  group('the selection survives nothing that should outlive it', () {
    test('a reload prunes ids whose messages are gone', () {
      expect(fn('Future<void> _reload()'), contains('_selection.prune(_ids)'));
    });

    test('both clear paths drop the selection', () {
      // _onClearedBroadcast was fixed and the local one was not, which left a
      // bar reading "5 selected" over an empty conversation.
      for (final f in [
        'void _onClearedBroadcast',
        'Future<void> _clearConversation()',
      ]) {
        expect(fn(f), contains('_selection.clear()'), reason: f);
      }
    });
  });

  group('selection is not a trap', () {
    test('back leaves the selection before it leaves the chat', () {
      expect(chat, contains('canPop: !_selecting'));
    });

    test('back closes the shell drawer first, if it is open', () {
      // PopScope parks a PopEntry on the same route the drawer uses for its
      // history entry, and refusing the pop jumps that queue — so back with
      // the drawer open ate the press and cleared an invisible selection.
      final body = fn('Widget build(BuildContext context)');
      expect(body, contains('shell.isDrawerOpen'));
      expect(
          body.indexOf('closeDrawer'), lessThan(body.indexOf('_clearSelection')),
          reason: 'the drawer has to win, or the press is swallowed',);
    });

    test('the bar carries a visible way out', () {
      final at = chat.indexOf(r'${_selection.length} selected');
      expect(at, greaterThan(-1), reason: 'the bar should show a count');
      final bar = chat.substring(at - 900, at + 200);
      expect(bar, contains('onPressed: _clearSelection'));
      expect(bar, contains('Icons.close'));
    });
  });

  group('nothing the removed sheet did was lost', () {
    test('the per-message sheet is gone, not merely unreachable', () {
      expect(chat.contains('_showMessageActions'), isFalse);
    });

    test('reply and save survive, bound once per frame', () {
      // Re-read at tap time, a realtime delete between build and pointer-up
      // turns the null check stale and the bang into a crash.
      expect(chat, contains('final one = _onlySelected;'));
      expect(chat, contains('_startReply(one)'));
      expect(chat, contains('_saveMessageMedia(one)'));
    });
  });

  test('the delete button goes quiet while a batch is running', () {
    expect(chat, contains('_selection.busy'));
  });

  test('the input bar does not describe the sweep as local', () {
    // The comment above the sweep button said 'local & instant, partner
    // unaffected' while the callback it is bound to runs
    // clear_conversation_everyone. The RPC's name is the only honest
    // description; the 'clear for me' half-mechanism has no writer.
    final bar =
        File('lib/features/chat/widgets/chat_input_bar.dart').readAsStringSync();
    final at = bar.indexOf('widget.onClearConversation != null');
    expect(at, greaterThan(0));
    final above = bar.substring(at - 400 < 0 ? 0 : at - 400, at);
    expect(above, isNot(contains('partner unaffected')));
    expect(above, contains('clear_conversation_everyone'));
  });
}
