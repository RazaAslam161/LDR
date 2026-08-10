import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The call controller has two ways in for an incoming call — the realtime
/// offer and the FCM/`call_invites` path — and they used to set up the ring
/// separately. One of them set `isVideo` and the other did not, so while the
/// phone was ringing the flag still held whatever the PREVIOUS call left
/// behind: an audio call announced itself as an incoming video call, and after
/// an audio call the next video call rang as audio.
///
/// The media was always right. Only the screen lied, which is the kind of bug
/// that survives testing by hand because answering it fixes it.
///
/// The fix was to funnel both paths through one `_ring`. This keeps it that
/// way: two entry points is two chances to forget.
void main() {
  final source =
      File('lib/features/call/call_controller.dart').readAsStringSync();

  test('only one place puts the app into the ringing state', () {
    final sites = '_setState(CallState.ringing)'.allMatches(source).length;
    expect(
      sites,
      1,
      reason: 'ringing is set up in $sites places. Every field the ringing UI '
          'reads (isVideo, peerName, _pendingOffer, isCaller) has to be set at '
          'each one, and the last time there were two, isVideo was missed.',
    );
  });

  test('the ring sets the call type', () {
    // Guards the specific field that was missed. The ringing screen reads
    // isVideo directly (call_screen.dart), so if _ring stops assigning it the
    // display goes back to showing the previous call's type.
    // Bounded by the next member, not by a closing brace: '\n  }' also matches
    // the '\n  }) {' that ends a multi-line parameter list, which would leave
    // this reading the signature and nothing else.
    final body = source.substring(
      source.indexOf('void _ring('),
      source.indexOf('Future<void> accept()'),
    );
    expect(body, contains('isVideo = video'),
        reason: '_ring must set isVideo, or the ringing screen shows the '
            'type of whatever call happened last',);
    expect(body, contains('_setState(CallState.ringing)'));
  });

  test('accept does not decide the call type', () {
    // It is too late by then: the user has already been shown, and answered,
    // a call labelled with the wrong type.
    final accept = source.substring(source.indexOf('Future<void> accept()'));
    final body = accept.substring(0, accept.indexOf('\n  void decline()'));
    expect(body.contains('isVideo ='), isFalse,
        reason: 'the call type must be settled when it starts ringing, '
            'not when it is answered',);
  });
}
