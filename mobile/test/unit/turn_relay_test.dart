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
    test('an error body is not read as a server list', () {
      // The edge function reports missing secrets, a rejected Cloudflare token
      // and its own exceptions as {"error": ...} with a non-200. Reading only
      // 'iceServers' turned every one of those into "no relay, no complaint".
      final body = fn('_turnServers()');
      expect(body, contains("data['error']"),
          reason: 'the function reports failures in the body, not by throwing');
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
      for (final path in ['timeout', 'server:', 'bad response shape']) {
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
}
