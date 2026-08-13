import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_controller.dart';

/// Both partners pressing Call inside the same window used to mean NEITHER
/// phone rang. `_onSignal` dropped any inbound offer while `state != idle`, so
/// each device silently discarded the other's offer and both sat on "Calling…"
/// until the 35s timeout — the one failure mode that looks identical, from both
/// sides at once, to a partner who simply did not answer.
///
/// The fix is decided twice, once on each handset, from two operands both
/// devices already hold. It is therefore only correct if the two answers are
/// mirror images: a disagreement is not a degraded call, it is no call at all,
/// in both directions.
void main() {
  final src = File('lib/features/call/call_controller.dart').readAsStringSync();

  String fn(String signature) {
    final at = src.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature should exist');
    final bodyStart = src.indexOf('{', at);
    return src.substring(at, src.indexOf('\n  }', bodyStart));
  }

  /// Bounded by the next member rather than by a closing brace: '\n  }' also
  /// matches the '\n  }) async {' that ends a multi-line parameter list, which
  /// leaves [fn] reading the signature and nothing else.
  /// Empty rather than throwing when either end is missing: this runs while
  /// the groups are being declared, where an expect() is an OutsideTestException.
  String between(String signature, String next) {
    final at = src.indexOf(signature);
    final end = at < 0 ? -1 : src.indexOf(next, at);
    return end < at ? '' : src.substring(at, end);
  }

  group('the tie-break both phones compute', () {
    const lower = '0a1b2c3d-1111-4222-8333-444455556666';
    const higher = 'f0e1d2c3-1111-4222-8333-444455556666';

    test('the lower id keeps its outgoing call', () {
      expect(callGlareFor(mine: lower, theirs: higher), CallGlare.keepMine);
    });

    test('the higher id yields', () {
      expect(callGlareFor(mine: higher, theirs: lower), CallGlare.yieldToPeer);
    });

    test('case cannot change the answer', () {
      // 'F' is 0x46 and 'a' is 0x61, so a raw compare puts 'F…' BELOW 'a…'
      // while a lowercased one puts it above — an id that round-tripped through
      // a payload in the other case would flip exactly one device, and both
      // would then keep their own call. v4() and Postgres both render lower
      // case today, so this pins a contract rather than reporting a live bug.
      const upper = 'F1111111-1111-4222-8333-444455556666';
      const lowerA = 'a1111111-1111-4222-8333-444455556666';
      expect(callGlareFor(mine: upper, theirs: lowerA), CallGlare.yieldToPeer);
      expect(callGlareFor(mine: lowerA, theirs: upper), CallGlare.keepMine);
      // And the same id in two cases is the SAME id, not a winner.
      expect(
        callGlareFor(
          mine: '3F8A1C2E-1111-4222-8333-444455556666',
          theirs: '3f8a1c2e-1111-4222-8333-444455556666',
        ),
        CallGlare.undecidable,
      );
    });

    test('two equal ids decide nothing rather than deciding twice', () {
      // Equal operands are the one input that cannot produce mirror answers:
      // both sides would compute the same verdict about themselves, so both
      // would keep, or both would yield.
      expect(callGlareFor(mine: lower, theirs: lower), CallGlare.undecidable);
    });

    test('an offer with no id decides nothing', () {
      for (final theirs in <String?>[null, '']) {
        expect(callGlareFor(mine: lower, theirs: theirs),
            CallGlare.undecidable, reason: 'theirs=$theirs',);
      }
      for (final mine in <String?>[null, '']) {
        expect(callGlareFor(mine: mine, theirs: higher),
            CallGlare.undecidable, reason: 'mine=$mine',);
      }
    });

    test('for any two distinct ids exactly one side yields', () {
      // The property the whole design rests on. Neither device can see the
      // other's verdict, so "one keeps and one yields" has to hold for every
      // pair, not for the pairs someone thought to write down.
      const ids = [
        '00000000-0000-4000-8000-000000000000',
        '0a1b2c3d-1111-4222-8333-444455556666',
        '3f8a1c2e-1111-4222-8333-444455556666',
        'F1111111-1111-4222-8333-444455556666',
        'a1111111-1111-4222-8333-444455556666',
        'deadbeef-9999-4999-8999-999999999999',
        'f0e1d2c3-1111-4222-8333-444455556666',
        'FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF',
      ];
      for (final a in ids) {
        for (final b in ids) {
          if (a.toLowerCase() == b.toLowerCase()) continue;
          final mine = callGlareFor(mine: a, theirs: b);
          final theirs = callGlareFor(mine: b, theirs: a);
          expect(
            {mine, theirs},
            {CallGlare.keepMine, CallGlare.yieldToPeer},
            reason: '$a vs $b decided $mine / $theirs — a pair where both '
                'keep is two phones on "Calling…", and a pair where both '
                'yield is two phones answering a call nobody is placing',
          );
        }
      }
    });
  });

  group('a peer that cannot yield is not tie-broken against', () {
    test('the offer advertises that this build honours the tie-break', () {
      expect(fn('Future<void> startCall('), contains("'glare': true"),
          reason: 'without it the peer cannot tell this build apart from one '
              'that drops every offer it receives while busy',);
    });

    test('an offer without it is yielded to outright', () {
      // Build 9 sends call_id on every signal and can still only KEEP, so a
      // tie-break against it loses half of all mixed-build double-dials to the
      // exact 35s both-phones-calling failure this change deletes.
      final body = fn('void _onSignal(');
      expect(body, contains("map['glare'] as bool? ?? false"));
      final decision = body.substring(body.indexOf('final glare ='));
      expect(decision.indexOf('peerYields'),
          lessThan(decision.indexOf('callGlareFor(')),
          reason: 'the tie-break must be reached only once the peer has said '
              'it honours the tie-break too',);
      expect(decision, contains('CallGlare.yieldToPeer'));
    });
  });

  group('the resolution path leaves the rescued call alive', () {
    final adopt = between('Future<void> _adoptAndAnswer(',
        'Future<int> _discardOutgoingForResolution(',);

    test('both halves of the resolution exist', () {
      expect(adopt, isNotEmpty,
          reason: '_adoptAndAnswer must be followed by the discard it calls',);
    });

    test('yielding does not run the teardown', () {
      // _teardown sets `ended`, nulls _pendingOffer, resets isVideo/camOn and
      // lands on idle 300ms later — so the answer would be built by a
      // controller on its way to idle, on a screen that pops itself when it
      // gets there.
      final body = fn('Future<int> _discardOutgoingForResolution(');
      expect(body.contains('_teardown'), isFalse);
      expect(body, contains('_pendingRemote'),
          reason: 'the peer built ONE connection, so what is already queued '
              'from it belongs to the call that survives',);
    });

    test('the peer connection is unhooked before it is disposed', () {
      // dispose() fires onConnectionState(Closed) synchronously, and that
      // handler guards on identical(pc, _pc) — so disposing first tears down
      // the call this method exists to save.
      final body = fn('Future<int> _discardOutgoingForResolution(');
      expect(body.indexOf('_pc = null'), greaterThan(-1));
      expect(body.indexOf('_pc = null'),
          lessThan(body.indexOf('await pc?.dispose()')),);
    });

    test('the discarded connection stops being sampled', () {
      // Otherwise the 2s timer polls a disposed connection, and `stats` carries
      // the abandoned call's last sample into the adopted call's teardown row.
      final body = fn('Future<int> _discardOutgoingForResolution(');
      expect(body, contains('_statsMonitor.stop()'));
      expect(body, contains('stats = null'));
    });

    test('the abandoned invite is taken back', () {
      // The insert fires the push. Left behind, it rings the partner for a call
      // nobody is placing, and handlePendingCall checks only that it exists.
      final body = fn('Future<int> _discardOutgoingForResolution(');
      expect(body, contains('_deleteInvite'));
      expect(body, contains('whenComplete'),
          reason: 'the insert is not awaited, so an unchained delete races '
              'ahead of the row it is deleting',);
    });

    test('the adoption takes its generation from the discard', () {
      // The discard awaits two disposes. A hangup or a connect timeout landing
      // in them runs _teardown, and a generation read afterwards is blind to
      // it — the adoption then builds a live call under an idle controller.
      expect(adopt,
          contains('final attempt = await _discardOutgoingForResolution('),);
    });

    test('the adoption waits for a capture already in flight', () {
      // Android opens one camera per process, and the offer most often lands
      // inside getUserMedia — a second request there fails the adoption, which
      // ends both calls.
      expect(adopt, contains('_openingMedia'));
    });

    test('the adoption warms the relay before it builds the connection', () {
      // iceServers are read once, at construction; a relay that arrives after
      // _createPc cannot join the call at all.
      expect(adopt.indexOf('await _ensureRelay()'), greaterThan(-1));
      expect(adopt.indexOf('await _ensureRelay()'),
          lessThan(adopt.indexOf('await _createPc()')),);
    });

    test('the answer is not put on a channel that is not live', () {
      // _send drops what it cannot send, and the answer is the one message
      // whose loss the other phone cannot detect — it waits out its full 35s.
      expect(adopt.indexOf('_ensureChannel'),
          lessThan(adopt.indexOf("_send('answer'")),);
    });

    test('a hangup for the call being adopted is not filtered out', () {
      // For the width of the resolving window this device answers to two ids.
      // Dropping the winner's hangup left the yielder answering a call that no
      // longer existed, and waiting out the timeout to find out.
      expect(fn('void _onSignal('), contains('theirs != _resolvingCallId'));
    });

    test('an offer in the 300ms ended window still rings', () {
      // Every glare that could not be resolved ends with both people tearing
      // down and one of them immediately calling back.
      final body = fn('void _onSignal(');
      expect(body, contains('state == CallState.ended'));
    });
  });

  group('nothing outlives the attempt that opened it', () {
    test('the capture is not published by a superseded attempt', () {
      // The displaced stream stays attached to the surviving call's peer
      // connection, and _teardown disposes the field, not the orphan — so the
      // microphone outlives the call, the screen and the next call.
      final body = fn('Future<void> _openMedia(');
      expect(body.indexOf('if (attempt != _attempt)'),
          lessThan(body.indexOf('_localStream = stream')),);
    });

    test('the peer connection is not published by a superseded attempt', () {
      final body = fn('Future<void> _createPc(');
      expect(body.indexOf('if (attempt != _attempt)'),
          lessThan(body.indexOf('_pc = pc;')),);
    });

    test('every call path claims a generation before its first await', () {
      for (final f in ['Future<void> startCall(', 'Future<void> accept()']) {
        expect(fn(f), contains('final attempt = ++_attempt;'), reason: f);
      }
    });

    test('teardown invalidates in flight work and clears the call id', () {
      final body = fn('Future<void> _teardown(');
      expect(body, contains('_attempt++'));
      expect(body, contains('_callId = null'),
          reason: 'a stale id no longer just mislabels a trace — it decides '
              'which signals this device answers to',);
      expect(body, contains('_tearingDown'),
          reason: 'state is not written until four awaits in, so without this '
              'the glare branch adopts into a teardown',);
    });

    test('the glare branch refuses to adopt into a teardown', () {
      expect(fn('void _onSignal('), contains('!_tearingDown'));
    });

    test('the invite row id is passed, not read across the await', () {
      // Read from the field, a resolution landing inside the insert files the
      // row under the WINNER's id — whose own insert then fails on the primary
      // key, and that insert is the only thing that wakes a closed app.
      expect(src, contains('Future<void> _insertInvite(String id,'));
      expect(fn('Future<void> startCall('), contains('_insertInvite(_callId!'));
    });
  });

  test('the tie-break never consults a timestamp', () {
    // created_at ranks network latency (the broadcast precedes the insert, and
    // now() is transaction-start), and a time-ordered id ranks two handset
    // clocks this repo has measured seconds apart.
    final at = src.indexOf('CallGlare callGlareFor(');
    expect(at, greaterThan(-1));
    final body = src.substring(at);
    for (final banned in ['created_at', 'DateTime', 'now(']) {
      expect(body.contains(banned), isFalse, reason: banned);
    }
  });
}
