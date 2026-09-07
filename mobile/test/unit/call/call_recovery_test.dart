import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_screen.dart';

/// A call that loses its network had no arm at all.
///
/// `onConnectionState` handled Connected, Failed and Closed and nothing else,
/// so a wifi-to-mobile handover, a lift or a tunnel left the call mute until
/// ICE gave up on its own — and the teardown that followed said nothing, which
/// is indistinguishable from the partner hanging up.
///
/// The screen was as quiet: "Voice call · connected" was the whole readout for
/// the length of the call, so a call that had silently dropped minutes ago
/// looked exactly like one still running.
void main() {
  final src =
      File('lib/features/call/call_controller.dart').readAsStringSync();

  String fn(String head) {
    final at = src.indexOf(head);
    expect(at, greaterThan(-1), reason: '$head not found');
    return src.substring(at, src.indexOf(RegExp(r'\n  \}\r?\n'), at));
  }

  group('a lost connection is recovered, not merely watched', () {
    test('Disconnected arms a restart', () {
      expect(src,
          contains('RTCPeerConnectionState.RTCPeerConnectionStateDisconnected'),
          reason: 'the state a handover produces was not handled at all',);
      expect(src, contains('_armRestart(pc)'));
    });

    test('only the side that can repair it runs a clock', () {
      final arm = fn('void _armRestart(RTCPeerConnection pc) {');
      expect(arm, contains('if (!isCaller) return;'),
          reason: 'both sides re-offering is glare on a live connection, and '
              'the tie-break only runs from idle',);
      // This pinned the give-up clock ABOVE the return, on both sides. An
      // adversarial read showed that kills the callee's call at 20s inside the
      // window where libwebrtc's own ICE is still probing and would have
      // recovered — a timer that exists to explain dead calls, ending live
      // ones. The callee keeps the Failed arm, which now leaves a sentence.
      expect(arm.indexOf('!isCaller'), lessThan(arm.indexOf('_iceGiveUp ??=')));
    });

    test('the budget is per incident, and given back only on a stable link',
        () {
      // Two recovered handovers over a long call spent it, so the third — the
      // one that needed it — got no restart at all. An unconditional reset in
      // the Connected arm is the other failure: a link flapping every few
      // seconds would re-offer forever.
      expect(src, contains('_restartBudget = Timer(_restartBudgetResetAfter'));
      expect(src, contains('_restartBudgetResetAfter = Duration(seconds: 30)'));
      final teardown = fn('Future<void> _teardown(CallState end) async {');
      expect(teardown, contains('_restartBudget?.cancel();'));
    });

    test('the restart budget is bounded and the give-up says why', () {
      final restart = fn('Future<void> _restartIce(RTCPeerConnection pc) async {');
      expect(restart, contains('if (_iceRestarts >= _maxIceRestarts) return;'));
      expect(restart, contains("_send('reoffer'"),
          reason: 'never an offer with a flag — see the pinned-build law below',);
      final arm = fn('void _armRestart(RTCPeerConnection pc) {');
      expect(arm, contains('_lastError ='),
          reason: 'a call that ends by itself must leave a sentence behind',);
    });

    test('a restart is its own kind, which a pinned build ignores', () {
      // This pinned `offer` + a `restart` flag. Build 73 (3238b5f) does not
      // know that key: its _onSignal skips the foreign-id gate for offers and,
      // from idle, falls straight into _ring — so a caller whose call went
      // through a tunnel made the partner's phone show a full-screen INCOMING
      // CALL for a call that was already up. Its switch has nine cases and no
      // default arm, so a kind it has never heard of is silently ignored.
      expect(src, contains("_send('reoffer', {"));
      expect(src, isNot(contains("'restart': true,\n        'video': isVideo")));
      final signal = src.substring(src.indexOf('void _onSignal('));
      final restart = signal.indexOf("case 'reoffer':");
      final busy = signal.indexOf('if (state != CallState.idle)');
      expect(restart, greaterThan(-1));
      expect(restart, lessThan(busy),
          reason: 'the offer gate reads `connected` as busy and drops it',);
      final answer = fn('Future<void> _answerRestart(Map<String, dynamic> map) async {');
      expect(answer, contains('setRemoteDescription'));
      expect(answer, contains('createAnswer'));
      expect(answer, contains('identical(pc, _pc)'),
          reason: 'a teardown mid-answer must not publish onto the next call',);
    });

    test('Failed leaves a sentence, and never overwrites a better one', () {
      expect(src, contains('_lastError ??='),
          reason: 'the invite outcome and the relay error both say more',);
    });

    test('the reason is cleared where the attempt BEGINS, not at teardown', () {
      // The call screen consumes it as it pops, so a call whose screen never
      // mounted left its sentence standing to surface over the next one.
      final start = fn('Future<void> startCall(');
      expect(start, contains('_lastError = null;'));
      final teardown = fn('Future<void> _teardown(CallState end) async {');
      expect(teardown, isNot(contains('_lastError = null;')));
      expect(teardown, contains('_iceRestarts = 0;'));
      expect(teardown, contains('_connectedAt = null;'));
    });

    test('answering and failing tells the person, not only the server', () {
      final accept = fn('Future<void> accept() async {');
      final report = accept.indexOf("kind: 'call-accept'");
      expect(report, greaterThan(-1));
      expect(accept.indexOf('_lastError = _readableCallError(e)'),
          greaterThan(report),);
    });
  });

  group('the call says how long it has been running', () {
    test('the clock starts when the media path came up', () {
      expect(src, contains('_connectedAt ??= DateTime.now();'));
      expect(src, contains('Duration? get connectedFor'));
    });

    test('m:ss below the hour, h:mm:ss past it', () {
      expect(CallClock.format(const Duration(seconds: 7)), '0:07');
      expect(CallClock.format(const Duration(minutes: 4, seconds: 9)), '4:09');
      expect(CallClock.format(const Duration(minutes: 62, seconds: 5)),
          '1:02:05',);
    });

    test('the video call carries it too, and the stats do not outlive a call',
        () {
      final screen =
          File('lib/features/call/call_screen.dart').readAsStringSync();
      expect(screen, contains("ValueKey('call-clock-pill')"),
          reason: 'a connected video call drops the centrepiece entirely',);
      expect(screen, isNot(contains("'Voice call · connected'")));
      // Reset from the CONTROLLER's teardown, not from this screen: a call
      // ended while minimised has no screen mounted, and the PiP has no
      // hang-up — so every call the partner ends that way kept the overlay.
      expect(screen, contains('CallController.resetCallOverlays ??='));
      expect(src, contains('resetCallOverlays?.call();'));
    });
  });
}
