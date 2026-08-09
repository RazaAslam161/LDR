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
          reason: 'turn_not_configured and cloudflare_error arrive by throw');
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
      for (final path in ['timeout', 'HTTP \${e.status}', 'bad response shape']) {
        expect(body, contains(path), reason: 'unlabelled failure: $path');
      }
      expect(src, contains('static String? turnError'),
          reason: 'the reason has to outlive the fetch to be reportable');
    });
  });

  group('the app knows whether it can relay', () {
    test('the ice config records relay availability', () {
      expect(src, contains('relayAvailable = servers.any(_isRelay)'));
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
    expect(helper, contains("turn:"));
    expect(helper, contains("turns:"));
  });

  group('the diagnostics work on the calls that fail', () {
    test('sampling starts when the connection is created, not when it connects',
        () {
      // Started on Connected, the monitor only ever ran on calls that
      // SUCCEEDED — which are exactly the calls that never needed a relay. The
      // NO-RELAY banner was invisible in the one situation it exists for.
      final pc = fn('Future<void> _createPc()');
      expect(pc, contains('_statsMonitor.start(pc)'));
      final connected = src.substring(src.indexOf('onConnectionState'));
      expect(connected.substring(0, 600).contains('_statsMonitor.start'), isFalse,
          reason: 'starting it here makes it useless for failed calls');
    });

    test('accepting a call does not claim it is connected', () {
      // Set on local SDP alone, the callee showed "connected" over a black
      // screen while the caller still showed "Calling..." — two people, two
      // irreconcilable stories, neither describing the real failure.
      final accept = fn('Future<void> accept()');
      expect(accept.contains('_setState(CallState.connected)'), isFalse,
          reason: 'only onConnectionState may declare a call connected');
    });

    test('the callee gets a timeout too', () {
      // Its only exit was the caller hanging up. If that broadcast never
      // arrived, the wakelock and foreground service outlived a call that did
      // not exist.
      final accept = fn('Future<void> accept()');
      expect(accept, contains('_startConnectTimeout()'));
    });

    test('candidate types are logged', () {
      // ' typ host|srflx|relay' is the only line that answers whether TURN
      // actually allocated.
      expect(src, contains('local candidate typ='));
      expect(src, contains('onIceGatheringState'));
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
          reason: 'a cached entry with no relay is not worth restoring');
      expect(load, contains('Duration(hours: 20)'),
          reason: 'must expire before the 24h credential TTL does');
    });

    test('the cache is warmed before the first call', () {
      final init = fn('Future<void> init()');
      expect(init, contains('await loadCachedTurn()'),
          reason: 'restoring after the network fetch would defeat the point');
    });

    test('the fetch timeout is long enough for mobile data', () {
      // 8s was not: an edge function cold start on a slow connection exceeds it,
      // and the failure was silent.
      final body = fn('_turnServers()');
      expect(body, contains('Duration(seconds: 15)'));
    });
  });
}
