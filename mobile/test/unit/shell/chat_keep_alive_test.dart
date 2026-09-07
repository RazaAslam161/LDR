import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/unread_tally.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Changing tab used to DESTROY the conversation.
///
/// The shell built `bodies[bodyIndex]` straight into a Column, so moving to
/// Home disposed ChatScreen and coming back re-ran `_init` from nothing: a
/// full-screen spinner, a 300-row SELECT and 300 decrypts, on every single tap
/// of the Chat icon, forever — and the scroll position with it.
///
/// The fix cannot be a plain IndexedStack. §288 ruled that out and the reason
/// is in tab_dissolve.dart: a retained Touch body inverts its FLAG_SECURE on a
/// quick A-B-A bounce, and every retained body double-joins its per-couple
/// realtime topics into the documented joined-but-dead state. Only Chat is
/// kept; every other slot holds a SizedBox until it is selected.
String _code(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  // UnreadTally reads and writes prefs; without a mocked store every call is
  // a "Binding has not yet been initialized" line.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final shell =
      File('lib/features/shell/app_shell.dart').readAsStringSync();
  final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();

  group('the conversation survives a trip to Home', () {
    test('the bodies live in an IndexedStack', () {
      expect(_code(shell), contains('IndexedStack('));
      expect(_code(shell), isNot(contains('child: bodies[bodyIndex]')),
          reason: 'that is the swap that disposed the chat',);
    });

    test('ONLY the chat is retained', () {
      final code = _code(shell);
      final block = code.substring(code.indexOf('final bodies = <Widget>['));
      expect(block.substring(0, 400), contains('i == chatBody || i == bodyIndex'));
      expect(block.substring(0, 400), contains('SizedBox.shrink()'),
          reason: 'Touch keeps its mount-per-visit lifecycle, or its '
              'FLAG_SECURE inverts on an A-B-A bounce',);
    });

    test('the dissolve no longer remounts what it fades', () {
      final dissolve = File('lib/core/ui/tab_dissolve.dart').readAsStringSync();
      expect(_code(dissolve), isNot(contains('KeyedSubtree')),
          reason: 'a key that changes with the tab index would remount the '
              'whole stack — destroying the body it exists to keep',);
    });
  });

  group('mounted stopped meaning looked at', () {
    test('the shell answers it, and never during a build', () {
      expect(shell, contains('ChatScreen.visible.value = chatShowing'));
      final at = shell.indexOf('final chatShowing = identity == _chatTab;');
      expect(at, greaterThan(-1));
      expect(shell.substring(at - 400, at + 400),
          contains('addPostFrameCallback'),
          reason: 'this notifier has listeners that call setState',);
    });

    test('the shade and the count are cleared on VISIBILITY, not on mount', () {
      // _init now runs at launch, because the body is built on every tab.
      // Ungated, opening the app on Home would clear the shade entry and the
      // unread count for messages nobody had looked at.
      expect(chat, contains('void _readIfShowing('));
      final read = chat.substring(chat.indexOf('void _readIfShowing('));
      expect(read.substring(0, 400), contains('!_chatVisible'));
      expect(read.substring(0, 400), contains('UnreadTally.clear'));
      expect(read.substring(0, 400), contains('clearMessageNotification'));
      // And NOT from _init. The first cut called it there, which read a
      // notifier the shell had not corrected yet — and _chatVisible calls
      // ModalRoute.of(context), which asserts before initState completes and
      // in a release build just answers true. A cold launch onto Home wiped
      // the count, the shade entry and the cover dot for messages nobody had
      // looked at, in exactly the build that ships.
      expect(_code(chat), isNot(contains('_readIfShowing(couple.id)')));
    });

    test('the notifier starts FALSE, and the cover puts it back', () {
      // The shell is the only writer and it writes post-frame, so the
      // initialiser is the value for the whole of the first build — during
      // which the stack has already mounted the chat.
      expect(chat,
          contains('static final ValueNotifier<bool> visible = '
              'ValueNotifier<bool>(false);'),);
      final dispose = shell.substring(shell.indexOf('void dispose() {'));
      expect(dispose.substring(0, 500),
          contains('ChatScreen.visible.value = false'),
          reason: 'the cover replaces the router subtree, and this static '
              'would otherwise stay true for the whole covered session',);
    });

    test('arriving at the tab settles what was owed', () {
      expect(chat, contains('ChatScreen.visible.addListener(_onVisibilityChanged)'));
      final onVis = chat.substring(chat.indexOf('void _onVisibilityChanged()'));
      expect(onVis.substring(0, 600), contains('_settleOwedAck()'));
      expect(onVis.substring(0, 600), contains('_readIfShowing()'));
      // clear() zeroes the notifier itself; a refresh here would re-read the
      // key clear() is in the middle of removing and could put the count back.
      expect(onVis.substring(0, 600), isNot(contains('UnreadTally.refresh')));
    });
  });

  group('the badge means something', () {
    setUp(() {
      UnreadTally.count.value = 0;
      // The dedupe set is process-scoped by design, so one test's ids would
      // otherwise silence the next.
      UnreadTally.clear('c1');
    });

    test('a message is counted once, however many wires carry it', () async {
      // The realtime broadcast is the fast path and the postgres echo is the
      // durable one, so the same message arrives at least twice by design.
      // A foreground push can make it three.
      await UnreadTally.noteUnread('c1', 'm1');
      final first = UnreadTally.count.value;
      await UnreadTally.noteUnread('c1', 'm1');
      await UnreadTally.noteUnread('c1', 'm1');
      expect(UnreadTally.count.value, first);
    });

    test('a couple with nobody in it counts nothing', () async {
      await UnreadTally.noteUnread('', 'm2');
      expect(UnreadTally.count.value, 0);
      await UnreadTally.refresh(null);
      expect(UnreadTally.count.value, 0);
    });

    test('the nav bar reads it, and hides it on the tab it belongs to', () {
      expect(shell, contains('valueListenable: UnreadTally.count'));
      expect(shell, contains('isLabelVisible: unread > 0 && !chatShowing'));
    });

    test('the chat counts only LIVE arrivals the owner did not see', () {
      final code = _code(chat);
      expect(code, contains('UnreadTally.noteUnread(couple, m.id)'));
      final at = code.indexOf('UnreadTally.noteUnread(couple, m.id)');
      final guard = code.substring(at - 400, at);
      expect(guard, contains('!_chatVisible'));
      expect(guard, contains('isMine'),
          reason: 'a badge for your own message is not an unread message',);
      // A catch-up page replays messages a background push already counted on
      // disk, and the two dedupe sets live in different isolates.
      expect(guard, contains('live.contains(source)'));
    });

    test('the stored count is read at start, not only on a change', () {
      // ref.listen fires on a CHANGE, and on a cold start the couple is
      // usually already resolved — so the badge sat at its initialised zero
      // for every message that arrived while the app was closed.
      expect(shell, contains('_talliedFor'));
      expect(shell, contains('unawaited(UnreadTally.refresh(coupleNow))'));
    });

    test('a push counts too, because a covered install posts no notification',
        () {
      final fcm =
          File('lib/core/services/fcm_service.dart').readAsStringSync();
      expect(fcm, contains('UnreadTally.noteUnread(coupleId, msgId)'));
      expect(fcm, contains('!ChatScreen.visible.value'));
    });

    test('what a background push wrote is read back on resume', () {
      // The notifier lives in this process; the background isolate only has
      // the disk. Without this the badge showed only messages that arrived
      // with the app already open — the half that needs it least.
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('UnreadTally.refresh('));
      expect(shell, contains('unawaited(UnreadTally.refresh(next.couple?.id))'));
    });
  });
}
