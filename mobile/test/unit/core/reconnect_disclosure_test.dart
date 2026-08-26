import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Two properties of the reconnect surface that nothing else can catch, and
/// that a well-meaning edit would break without failing anything.
///
/// Both come from the same ruling: nothing announces an unpair. The database
/// half enforces it by answering one indistinguishable null for every negative
/// case; the client half can throw that away by drawing a control only when
/// there is something behind it.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String code(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
      .join('\n');

  test('the reconnect row is drawn unconditionally', () {
    // A row that appears only when a window is open announces the window to
    // whoever is holding the phone. It has to be there for everybody,
    // including accounts that never had a couple — which is why the sheet
    // itself has a "nothing to bring back" state.
    final page = code(read('lib/features/auth/couple_page.dart'));
    final call = page.indexOf('showReconnectSheet(');
    expect(call, greaterThan(-1), reason: 'the row has gone');

    // Walk back to the enclosing widget and assert no severance-state
    // condition guards it. `loading` is fine — that is not a disclosure.
    final before = page.substring(0, call);
    for (final leak in [
      'SeveranceState',
      'held != null',
      'held ==',
      'restorable',
    ]) {
      expect(before.contains(leak), isFalse,
          reason: 'the reconnect row is gated on $leak, which turns its mere '
              'presence into an announcement that a window is open',);
    }
  });

  test('the sheet answers the same way for every negative case', () {
    // The server returns one null for never-a-member, severed, expired,
    // purged and moved-on. The sheet must not try to tell them apart, and
    // must not ask anything that could.
    final sheet = code(read('lib/features/safety/reconnect_sheet.dart'));
    expect(sheet.contains('held == null'), isTrue,
        reason: 'the empty state must be one branch, not several',);
    for (final probe in ['severed', 'expired', 'purged', 'moved_on']) {
      expect(sheet.contains("'$probe'"), isFalse,
          reason: 'the sheet distinguishes $probe, which is an oracle',);
    }
  });

  test('the way out is never gated behind the way back', () {
    // Erasing must not require a password, a second sheet, or the other
    // person. Confirming a reunion must require a password, because that is
    // the one action here that completes a restoration on its own and a
    // grabbed unlocked phone can otherwise tap it.
    final sheet = code(read('lib/features/safety/reconnect_sheet.dart'));

    final erase = sheet.indexOf('leaveCouplePermanently');
    expect(erase, greaterThan(-1), reason: 'the permanent exit has gone');
    final eraseCall = sheet.substring(
        (erase - 400).clamp(0, sheet.length), erase,);
    expect(eraseCall.contains('_confirmIsReallyYou'), isFalse,
        reason: 'erasing must never be slower than reconnecting',);

    final confirm = sheet.indexOf('coupleRestoreConfirm');
    expect(confirm, greaterThan(-1));
    final confirmCall = sheet.substring(
        (confirm - 400).clamp(0, sheet.length), confirm,);
    expect(confirmCall.contains('_confirmIsReallyYou'), isTrue,
        reason: 'confirming completes a restoration alone and must re-auth',);
  });

  test('nothing on this surface notifies the other person', () {
    final sheet = code(read('lib/features/safety/reconnect_sheet.dart'));
    for (final call in ['FcmService', 'notify', 'SnackBarAction']) {
      expect(sheet.contains(call), isFalse, reason: '$call has no place here');
    }
  });
}
