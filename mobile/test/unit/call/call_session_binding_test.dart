import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_controller.dart';

/// Calling was bound to an account ONCE, at the first read of the provider, and
/// never again: `init()` returned early on `_inited`, `_coupleId` was assigned
/// nowhere else in the file, the provider is not auto-disposed and `signOut()`
/// never touched the controller.
///
/// Two ways for a real user to lose calling entirely, both silent:
///
///   * the couple had not resolved yet when the provider was first read — the
///     controller then had no couple for the rest of the process, so it never
///     subscribed and every signal was dropped;
///   * a second account signed in on the same handset — the controller kept the
///     FIRST couple, so the broadcast channel stayed `call:<old couple>` (which
///     the private-channel policy on realtime.messages denies) and every
///     `call_invites` row carried the old couple_id and the old caller_id (which
///     RLS refuses with 42501).
///
/// The decision lives in a pure function so it can be tested at all: the
/// controller itself cannot be constructed here — RTCVideoRenderer needs the
/// platform plugin — and the decision is the part that was wrong.
void main() {
  final src = File('lib/features/call/call_controller.dart').readAsStringSync();

  String fn(String signature) {
    final at = src.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature should exist');
    final bodyStart = src.indexOf('{', at);
    return src.substring(at, src.indexOf('\n  }', bodyStart));
  }

  group('binding follows the account that is signed in now', () {
    test('a fresh account binds when its couple finally resolves', () {
      // The race that disabled calling for a whole process. Nothing is bound,
      // the session has no couple yet, and then it does.
      expect(
        callBindingFor(
          authenticated: true,
          coupleId: null,
          userId: 'u1',
          boundCoupleId: null,
          boundUserId: null,
        ),
        CallBinding.unchanged,
      );
      expect(
        callBindingFor(
          authenticated: true,
          coupleId: 'c1',
          userId: 'u1',
          boundCoupleId: null,
          boundUserId: null,
        ),
        CallBinding.bind,
      );
    });

    test('signing out unbinds', () {
      // Or the next person to sign in on this handset inherits the topic, the
      // couple_id and the caller_id of the account that left.
      expect(
        callBindingFor(
          authenticated: false,
          coupleId: null,
          userId: null,
          boundCoupleId: 'c1',
          boundUserId: 'u1',
        ),
        CallBinding.clear,
      );
    });

    test('a second account on the same handset rebinds', () {
      expect(
        callBindingFor(
          authenticated: true,
          coupleId: 'c2',
          userId: 'u2',
          boundCoupleId: 'c1',
          boundUserId: 'u1',
        ),
        CallBinding.bind,
      );
    });

    test('a partner signing in rebinds even though the couple is the same', () {
      // Both members share the couple id, so only _myUid changes — and _myUid
      // is the caller_id every invite is written with, and the filter that
      // decides which broadcasts are this device's own echo.
      expect(
        callBindingFor(
          authenticated: true,
          coupleId: 'c1',
          userId: 'u2',
          boundCoupleId: 'c1',
          boundUserId: 'u1',
        ),
        CallBinding.bind,
      );
    });

    test('a couple that momentarily reads null does not unbind', () {
      // The couple goes null on every resume (main.dart says so). Treating that
      // as a sign-out would drop the channel a live call is signalling on.
      expect(
        callBindingFor(
          authenticated: true,
          coupleId: null,
          userId: 'u1',
          boundCoupleId: 'c1',
          boundUserId: 'u1',
        ),
        CallBinding.unchanged,
      );
    });

    test('an unchanged session does not churn the channel', () {
      expect(
        callBindingFor(
          authenticated: true,
          coupleId: 'c1',
          userId: 'u1',
          boundCoupleId: 'c1',
          boundUserId: 'u1',
        ),
        CallBinding.unchanged,
      );
      expect(
        callBindingFor(
          authenticated: false,
          coupleId: null,
          userId: null,
          boundCoupleId: null,
          boundUserId: null,
        ),
        CallBinding.unchanged,
      );
    });
  });

  group('the wiring that makes the decision reach the controller', () {
    test('the couple is bound from the session, not read once', () {
      // A one-shot read is the bug. The listener has to fire again — on the
      // couple resolving late AND on a different account signing in.
      final provider = src.substring(src.indexOf('final callControllerProvider'));
      expect(provider, contains('ref.listen<SessionState>'));
      expect(provider, contains('sessionProvider'));
      expect(provider, contains('bindSession'));
      expect(provider, contains('fireImmediately: true'),
          reason: 'a session that had already resolved would never fire, '
              'which is the same silent dead controller in a new place',);
    });

    test('init() no longer decides who you are', () {
      // It runs once per process and returns early forever after; anything
      // account-shaped inside it is unreachable on the second account.
      final init = fn('Future<void> init()');
      expect(init.contains('_coupleId'), isFalse);
      expect(init.contains('_myUid'), isFalse);
      expect(init.contains('_subscribeChannel'), isFalse);
    });

    test('the couple id is assigned in exactly one place', () {
      // The original defect was one write, in a method guarded to run once.
      final writes = RegExp('_coupleId = ').allMatches(src).length;
      expect(writes, 1, reason: 'a second assignment is a second thing to '
          'forget when the account changes',);
      expect(fn('Future<void> bindSession('), contains('_coupleId = coupleId'));
    });
  });

  group('a call that cannot signal fails loudly', () {
    test('a refused subscribe retries instead of sitting dead', () {
      // Eight subscribe failures in a field trace and not one retry: every call
      // after the first was sent into a channel the server had closed.
      expect(src, contains('void _scheduleResubscribe()'));
      expect(src, contains('_resubscribeTimer'));
      final sched = src.substring(src.indexOf('void _scheduleResubscribe()'));
      expect(sched.substring(0, 400), contains('_subscribeAttempt'),
          reason: 'a denial can be permanent — retrying it flat out is a '
              'reconnect storm',);
    });

    test('the subscribe records which topic was judged', () {
      // The channel is private; the RLS policy on realtime.messages judges the
      // TOPIC. Without it, a denial on the couple you left and a denial on your
      // own couple are the same row.
      final sub = src.substring(src.indexOf("'signal_subscribe'"));
      expect(sub.substring(0, 300), contains("'topic': topic"));
    });

    test('both call paths refuse to start without a live channel', () {
      for (final f in ['Future<void> startCall(', 'Future<void> accept()']) {
        final body = fn(f);
        expect(body, contains('if (!await _ensureChannel())'), reason: f);
        expect(body, contains('_failWithoutChannel'), reason: f);
        expect(body.indexOf('_ensureChannel'), lessThan(body.indexOf('_send(')),
            reason: '$f must not put signals on a channel that is not live',);
      }
    });

    test('an unbound controller does not silently do nothing', () {
      // The Call button used to return on `_coupleId == null` before it changed
      // any state — no row, no screen, no message — on precisely the devices
      // whose binding had gone wrong.
      final body = fn('Future<void> startCall(')
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(body.contains('_coupleId == null'), isFalse,
          reason: 'an unbound controller has to fail through the channel gate, '
              'which tells the user something',);
    });

    test('the user is told, rather than left at the timeout', () {
      // takeLastError is read by the call screen as it pops; without a message
      // set, the whole failure is a flash of an empty screen.
      expect(fn('void _failWithoutChannel('), contains('_lastError'));
      final timeout = src.substring(src.indexOf("'connect_timeout'"));
      expect(timeout.substring(0, 900), contains('_lastError'),
          reason: '35 seconds of "Calling…" and then nothing at all',);
    });
  });

  group('a first call on a device with nothing cached', () {
    test('waits longer when there is no relay to fall back on', () {
      // iceServers are read once, when the peer connection is constructed, and
      // setConfiguration is called nowhere in this file — so credentials that
      // land after _createPc cannot join the call. A warm device loses nothing
      // by a 3s budget; a fresh install loses its relay for the whole call.
      expect(src, contains('_coldRelayBudget'));
      expect(src, contains('_warmRelayBudget'));
      final at = src.indexOf('static Future<void> _ensureRelay(');
      final ensure = src.substring(at, src.indexOf('\n  }', src.indexOf('async {', at)));
      expect(ensure, contains('_cachedTurn.isEmpty'),
          reason: 'the budget has to depend on whether anything is cached',);
      expect(ensure, contains('.timeout(budget)'));
      // Comments stripped: the comment explaining WHY setConfiguration is not
      // called would otherwise fail the check that it is not called.
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('setConfiguration'), isFalse,
          reason: 'if this ever appears, late credentials become possible and '
              'the wait can be shortened again',);
    });

    test('the wait is bounded below the peer timeout', () {
      // The callee tears down at 35s. A relay wait that eats it is a call that
      // cannot connect by arithmetic — which is how this went wrong before.
      final cold = RegExp(r'_coldRelayBudget = Duration\(seconds: (\d+)\)')
          .firstMatch(src);
      expect(cold, isNotNull);
      expect(int.parse(cold!.group(1)!), lessThanOrEqualTo(10));
    });
  });
}
