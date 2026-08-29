import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The initiator lands on the re-link screen ONCE per ceremony.
///
/// _offerUnlink is fired from three places that repeat for the whole seven
/// days — the socket re-open fan-out (every doze recovery, every resume), every
/// write the partner makes to the row, and every mount — and both of its
/// original guards were shorter-lived than the ceremony: a field that exists
/// only for the duration of the awaited push, and a route check that only
/// answers for whatever is on top right now. So the landing repeated for a
/// week, over whatever the user was doing.
///
/// Source-read, like the ceremony's other laws next door: the path needs a
/// database, a platform channel and a router to exercise.
void main() {
  final shell =
      File('lib/features/shell/app_shell.dart').readAsStringSync();

  test('the landing is latched by something that outlives the push', () {
    final at = shell.indexOf('Future<void> _offerUnlink()');
    final end = shell.indexOf('Future<void> _executeUnlink(');
    expect(at, greaterThan(-1));
    expect(end, greaterThan(at));
    final body = shell.substring(at, end);

    expect(body.contains('SharedPreferences'), isTrue,
        reason: 'an in-memory latch dies with the State on every cover flip, '
            'and the shell remounts constantly under the disguise',);
    expect(body.contains('startedAt'), isTrue,
        reason: 'keyed on the ceremony itself, or ending again after a '
            're-link would never land anyone',);
    expect(body.indexOf('setString'),
        lessThan(body.indexOf("context.push('/unlink')")),
        reason: 'written BEFORE the push — the push is awaited for as long as '
            'the user stands on the screen, and every trigger firing '
            'meanwhile would read a latch that is not there yet',);
  });
}
