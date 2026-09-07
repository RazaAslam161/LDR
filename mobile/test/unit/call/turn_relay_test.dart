import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A missing TURN relay is invisible to whoever is testing.
///
/// Two phones on one wifi connect on host candidates and never need a relay, so
/// calling works perfectly for the developer. Two people behind different
/// carrier NATs almost always need one. That is why "calls work" and "calls are
/// broken for every real pair of users" were true at the same time.
///
/// The failure was silent by construction: every error from the credentials
/// function was caught and turned into an empty server list. These pin the
/// three ways it now refuses to be silent.
void main() {
  final src =
      File('lib/features/call/call_controller.dart').readAsStringSync();

  String fn(String name) {
    final at = src.indexOf(name);
    expect(at, greaterThan(-1), reason: '$name should exist');
    return src.substring(at, src.indexOf('\n  }', at));
  }

  group('a missing relay cannot pass as success', () {
    test('a non-2xx from the function is caught with its status and body', () {
      // functions_client THROWS for anything outside 2xx
      // (functions_client.dart:183-190), so the failure body arrives as
      // FunctionException.details — never as res.data. An earlier version of
      // this test pinned a `data['error']` read that could never execute, which
      // is worse than no test: it made dead code look load-bearing.
      final body = fn('_turnServers()');
      expect(body, contains('on FunctionException catch'),
          reason: 'turn_not_configured and cloudflare_error arrive by throw',);
      expect(body, contains('e.status'));
      expect(body, contains('e.details'));
    });

    test('a failed fetch backs off instead of costing every call', () {
      // The fetch sits in front of _createPc, so with a broken function the
      // user waits the whole timeout before the offer is even sent — on every
      // single attempt.
      expect(src, contains('_turnFailedAt'));
      final body = fn('_turnServers()');
      expect(body, contains('Duration(seconds: 60)'));
    });

    test('a response with no turn: entry is rejected', () {
      // Cloudflare returns STUN entries alongside TURN. Counting a
      // STUN-only response as success is exactly how a misconfigured project
      // looks healthy until two users are on different networks.
      final body = fn('_turnServers()');
      expect(body, contains('relays == 0'));
    });

    test('every failure path records a reason', () {
      final body = fn('_turnServers()');
      for (final path in ['timeout', r'HTTP ${e.status}', 'bad response shape']) {
        expect(body, contains(path), reason: 'unlabelled failure: $path');
      }
      expect(src, contains('static String? turnError'),
          reason: 'the reason has to outlive the fetch to be reportable',);
    });
  });

  group('the app knows whether it can relay', () {
    test('relay availability is derived from the cache, not a side effect', () {
      // It used to be a static assigned only inside _iceConfig, so the callee
      // — which rings before it ever builds a peer connection — read false
      // unconditionally and showed a "no relay" banner on a healthy device.
      expect(src, contains('static bool get relayAvailable'));
      expect(src, contains('static bool? get relayKnown'),
          reason: '"not fetched yet" is not the same as "no relay"',);
    });

    test('placing a call without a relay is logged as a warning', () {
      // Otherwise the user gets 35 seconds of "Calling..." and no explanation,
      // which is indistinguishable from every other call failure.
      expect(src, contains('if (!relayAvailable)'));
    });

    test('the stats readout can say NO-RELAY', () {
      final stats =
          File('lib/features/call/call_stats.dart').readAsStringSync();
      expect(stats, contains('NO-RELAY'));
      expect(src, contains('_statsMonitor.noRelay = !relayAvailable'));
    });
  });

  test('a relay is recognised by scheme, not by hostname', () {
    // Hostnames change; turn:/turns: is what actually makes it a relay.
    final helper = fn('static bool _isRelay');
    expect(helper, contains('turn:'));
    expect(helper, contains('turns:'));
  });

  group('the diagnostics work on the calls that fail', () {
    test('a refused invite is never reported as the partner not answering',
        () {
      // enforce_send_rate refuses a redial inside 15s with PT429; the insert
      // is unawaited and its failure went to Diag alone, so the 35s timeout
      // blamed the callee for a ring that never existed.
      final insert = fn('Future<void> _insertInvite(');
      expect(insert, contains('PT429'));
      expect(insert, contains('_InviteOutcome.rateLimited'));
      final sentence = fn('void _startConnectTimeout()');
      expect(sentence.indexOf('_inviteOutcome'),
          lessThan(sentence.indexOf('_remoteCandTypes.isEmpty')),
          reason: 'the invite outcome decides the sentence before candidates do',);
      // This pinned the literal 'was not rung' until an adversarial read
      // showed it was itself false: startCall BROADCASTS the offer before the
      // row is written, and a partner whose app is open rings off that
      // broadcast with no row involved. So a refused insert may not assert
      // anything about their phone — only about the call being registered,
      // which is what wakes a CLOSED app. What the law protects is unchanged:
      // an invite failure must never be reported as the partner ignoring it.
      // Scoped to the two INVITE arms. The default arm may still say the
      // partner never answered: it fires when the row landed, so the ring
      // did happen and silence really was silence.
      final invite = sentence.substring(
        sentence.indexOf('_InviteOutcome.rateLimited'),
        sentence.indexOf('_ => _remoteCandTypes'),
      );
      expect(invite, isNot(contains('never answered')));
      expect(invite, isNot(contains('was not rung')));
      expect('if their app was'.allMatches(invite).length, 2,
          reason: 'both invite sentences stay conditional on a closed app',);
      final teardown = fn('Future<void> _teardown(');
      expect(teardown, contains('_inviteOutcome = _InviteOutcome.pending'));
    });

    test('sampling starts when the connection is created, not when it connects',
        () {
      // Started on Connected, the monitor only ever ran on calls that
      // SUCCEEDED — which are exactly the calls that never needed a relay. The
      // NO-RELAY banner was invisible in the one situation it exists for.
      final pc = fn('Future<void> _createPc()');
      expect(pc, contains('_statsMonitor.start(pc)'));
      final connected = src.substring(src.indexOf('onConnectionState'));
      expect(connected.substring(0, 600).contains('_statsMonitor.start'), isFalse,
          reason: 'starting it here makes it useless for failed calls',);
    });

    test('accepting a call does not claim it is connected', () {
      // Set on local SDP alone, the callee showed "connected" over a black
      // screen while the caller still showed "Calling..." — two people, two
      // irreconcilable stories, neither describing the real failure.
      final accept = fn('Future<void> accept()');
      expect(accept.contains('_setState(CallState.connected)'), isFalse,
          reason: 'only onConnectionState may declare a call connected',);
    });

    test('the callee gets a timeout too', () {
      // Its only exit was the caller hanging up. If that broadcast never
      // arrived, the wakelock and foreground service outlived a call that did
      // not exist.
      final accept = fn('Future<void> accept()');
      expect(accept, contains('_startConnectTimeout()'));
    });

    test('candidate types are recorded, ours AND theirs', () {
      // ' typ host|srflx|relay' is the only line that answers whether TURN
      // actually allocated. It used to reach debugPrint, which reaches logcat,
      // which reaches whichever of the two phones has a cable in it — so the
      // one fact that decides a failed call was unavailable on the device that
      // failed. It goes to the trace now.
      expect(src, contains("'ice_local_candidate'"));
      expect(src, contains('onIceGatheringState'));

      // The asymmetry that made this undiagnosable for months: local candidates
      // were logged and REMOTE ones were not, so "their candidates never
      // arrived" and "TURN never allocated here" produced an identical 35s
      // timeout.
      expect(src, contains("'ice_remote_candidate'"));
    });
  });

  group('a slow network cannot leave a user without a relay', () {
    test('credentials survive a restart', () {
      // Credentials live 24h. Without persisting them, every cold start depends
      // on a fresh round trip finishing before the first call — and on a slow
      // mobile network that is exactly when it does not. The user is then
      // STUN-only and cannot reach anyone on another network.
      expect(src, contains('loadCachedTurn'));
      expect(src, contains('_persistTurn'));
      final load = fn('static Future<void> loadCachedTurn()');
      expect(load, contains('_isRelay'),
          reason: 'a cached entry with no relay is not worth restoring',);
      expect(load, contains('Duration(hours: 20)'),
          reason: 'must expire before the 24h credential TTL does',);
    });

    test('the cache is warmed before the first call', () {
      final init = fn('Future<void> init()');
      expect(init, contains('await loadCachedTurn()'),
          reason: 'restoring after the network fetch would defeat the point',);
    });

    test('the fetch timeout is long enough for mobile data', () {
      // 8s was not: an edge function cold start on a slow connection exceeds it,
      // and the failure was silent.
      final body = fn('_turnServers()');
      expect(body, contains('Duration(seconds: 15)'));
    });
  });

  group("a brand new user's FIRST call", () {
    test('both sides ensure a relay before creating the connection', () {
      // A fresh install has nothing cached, so its first call depends entirely
      // on one network fetch landing — on mobile data, against a cold edge
      // function, which is exactly the fetch most likely to miss.
      for (final f in ['Future<void> startCall(', 'Future<void> accept()']) {
        final body = fn(f);
        expect(body, contains('await _ensureRelay()'), reason: f);
        expect(body.indexOf('_ensureRelay'), lessThan(body.indexOf('_createPc')),
            reason: 'the relay must be in the ICE config, so it has to be '
                'fetched BEFORE the peer connection is built',);
      }
    });

    test('the relay fetch cannot sit unbounded in front of a call', () {
      // This test used to REQUIRE a `_cachedTurn.isNotEmpty &&` guard on the
      // backoff, pinning the defect as if it were the fix: that guard disabled
      // the backoff in exactly the case it existed for — nothing cached and
      // the function failing — so a cold cache retried 15s at a time, three
      // times, before the offer was even sent. 45s against the peer's own 35s
      // timeout: the call could not connect, by arithmetic.
      // Sliced by hand: fn() cuts at the first '\n  }', which here matches the
      // '})' closing _ensureRelay's own multi-line parameter list.
      final at = src.indexOf('static Future<void> _ensureRelay(');
      expect(at, greaterThan(-1));
      // Anchor past 'async {': _ensureRelay's parameter list is multi-line, so
      // both fn() and a naive '{' scan stop at the '})' that closes it.
      final bodyStart = src.indexOf('async {', at);
      final ensure = src.substring(at, src.indexOf('\n  }', bodyStart));
      expect(ensure, contains('Duration budget'));
      expect(ensure, contains('.timeout(budget)'),
          reason: 'the budget has to be enforced, not merely declared',);
      expect(ensure, contains('TimeoutException'),
          reason: 'and exceeding it must proceed, not abort the call',);

      // And the peer-connection path must never touch the network at all.
      // Comments stripped first: the comment explaining that this USED to
      // await _turnServers() otherwise fails the assertion about what the code
      // now does — a correct fix reported as a regression.
      final ice = fn('static Future<Map<String, dynamic>> _iceConfig()')
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(ice.contains('await _turnServers()'), isFalse,
          reason: 'building the connection must not block on a fetch',);
      expect(ice, contains('_cachedTurn'));
    });
  });
}
