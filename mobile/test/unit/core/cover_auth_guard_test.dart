import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/partner_rewrap.dart';

/// The cover and the OS unlock must never fight (BRAIN §167, plan P0-A).
///
/// The failure this pins: the PIN/pattern credential Activity reports
/// `paused`, the cover swap replaced the whole MaterialApp, and the rewrap
/// ceremony's State — six typed digits included — was destroyed mid-unlock.
/// Everything here reads source, because which lifecycle branch fires is a
/// platform fact no widget test can produce.
/// substring with the end clamped — an anchor near EOF must not RangeError.
String sliceFrom(String s, int start, int length) =>
    s.substring(start, start + length > s.length ? s.length : start + length);

void main() {
  final mainSrc = File('lib/main.dart').readAsStringSync();
  final lockSrc =
      File('lib/core/services/app_lock.dart').readAsStringSync();
  final screenSrc =
      File('lib/features/auth/rewrap_screen.dart').readAsStringSync();
  final shellSrc =
      File('lib/features/shell/app_shell.dart').readAsStringSync();
  final rewrapSrc =
      File('lib/core/data/partner_rewrap.dart').readAsStringSync();

  group('the authInProgress guard', () {
    test('the paused/hidden branch honors it', () {
      // The condition guarding raiseCover() in the paused case must name the
      // flag — `inactive` alone misses the credential-Activity flavour.
      final at = mainSrc.indexOf('case AppLifecycleState.paused:');
      expect(at, greaterThan(-1));
      final branch = mainSrc.substring(at, mainSrc.indexOf('case AppLifecycleState.detached:', at));
      expect(branch.contains('MilesApp.authInProgress'), isTrue,
          reason: 'paused raises the cover over a live OS prompt — the exact '
              'teardown that ate the ceremony code',);
    });

    test('the app lock does not arm over its own prompt', () {
      final at = mainSrc.indexOf('AppLock.lockIfEnabled();');
      expect(at, greaterThan(-1));
      // The 400 chars above the call hold its whole if-condition.
      final cond = mainSrc.substring(at < 400 ? 0 : at - 400, at);
      expect(cond.contains('authInProgress'), isTrue,
          reason: 'without this the ceremony prompt sets locked and the user '
              'unlocks twice back to back',);
    });

    test('AppLock.authenticate maintains the flag itself, with a finally', () {
      final at = lockSrc.indexOf('static Future<bool> authenticate()');
      expect(at, greaterThan(-1));
      final body = sliceFrom(lockSrc, at, 1400);
      final set = body.indexOf('authInProgress = true;');
      final await_ = body.indexOf('_auth.authenticate');
      expect(set, greaterThan(-1));
      expect(set, lessThan(await_),
          reason: 'the flag must be up BEFORE the prompt can background us',);
      final fin = body.indexOf('finally');
      expect(fin, greaterThan(-1));
      expect(body.substring(fin).contains('authInProgress = false;'), isTrue,
          reason: 'a stuck-true flag disables the disguise until process '
              'death — only a finally makes that impossible',);
    });

    test('MilesApp delegates — one backing bool, not two', () {
      expect(mainSrc.contains('static bool authInProgress = false;'), isFalse,
          reason: 'a second backing bool splits the guard: core call sites '
              'set one and the lifecycle reads the other',);
      expect(
          mainSrc.contains(
              'static bool get authInProgress => AppLock.authInProgress;'),
          isTrue,);
    });
  });

  group('the ceremony survives a teardown anyway', () {
    test('the outcome is recorded before the mounted checks', () {
      final at = screenSrc.indexOf('Future<void> _sendAnswer()');
      final body = sliceFrom(screenSrc, at, 4200);
      final sent = body.indexOf('RewrapAnswerStatus.sent = (id: req.id');
      final mountedAfterAnswer =
          body.indexOf('if (!mounted) return;', body.indexOf('PartnerRewrap.answer'));
      expect(sent, greaterThan(-1));
      expect(sent, lessThan(mountedAfterAnswer),
          reason: 'recorded after the mounted check is recorded never — '
              '!mounted is exactly the torn-down case',);
      expect(body.contains('RewrapAnswerStatus.failed = (id: req.id'), isTrue);
    });

    test('the fresh screen consumes the outcome before re-querying', () {
      final load = screenSrc.indexOf('Future<void> _load()');
      final firstQuery = screenSrc.indexOf('CryptoCore.heldRequest()', load);
      final consume = screenSrc.indexOf('RewrapAnswerStatus.sent', load);
      expect(consume, greaterThan(-1));
      expect(consume, lessThan(firstQuery),
          reason: 'querying pending() first re-derives the loop the record '
              'exists to break',);
    });

    test('status record semantics', () {
      RewrapAnswerStatus.sent = (id: 'x', dropped: 2);
      RewrapAnswerStatus.inFlight = 'x';
      expect(RewrapAnswerStatus.sent?.dropped, 2);
      RewrapAnswerStatus.sent = null;
      RewrapAnswerStatus.inFlight = null;
      expect(RewrapAnswerStatus.sent, isNull);
    });
  });

  group("the loop's other exits", () {
    test('the two rewrap subscriptions never share a topic', () {
      expect(screenSrc.contains(r"'rewrap:screen:$coupleId'"), isTrue);
      expect(shellSrc.contains(r"'rewrap:${couple.id}'"), isTrue);
      // Same topic twice = joined-but-dead (realtime_service.dart's own note).
      expect(shellSrc.contains('rewrap:screen:'), isFalse);
    });

    test('a both-keyless couple has a designed way out', () {
      final at = screenSrc.indexOf('Future<void> _offerStartFresh()');
      expect(at, greaterThan(-1));
      final body = sliceFrom(screenSrc, at, 3600);
      final release = body.indexOf('CryptoCore.releasePublication()');
      final clear = body.indexOf('CryptoCore.clearKeyless()');
      expect(release, greaterThan(-1));
      expect(clear, greaterThan(release),
          reason: 'a stale hold re-arms keyless at the next bindAccount and '
              'blocks publishing the stand-in key — release must come first',);
      // The cost is stated before the affirmative, and the affirmative is a
      // statement of fact, not an instruction.
      expect(body.contains('stay sealed forever'), isTrue);
      expect(body.contains('neither of us can read them'), isTrue);
    });

    test('a confirmed-readable answer clears the false keyless mark', () {
      final at = rewrapSrc.indexOf('if (readableConfirmed) await CryptoCore.clearKeyless();');
      expect(at, greaterThan(-1));
      // And only on that path: the unconditional form would clear a REAL
      // keyless mark and let escrow seal a stand-in key.
      expect(rewrapSrc.contains(RegExp(r'\n\s*await CryptoCore\.clearKeyless\(\);'
          r'\s*\n\s*return result\.dropped')), isFalse,);
    });

    test('the shell offer guard is route-aware, not only per-State', () {
      expect(shellSrc.contains('_rewrapRouteUp()'), isTrue);
      final offer = shellSrc.indexOf('Future<void> _offerRewrap(');
      final body = sliceFrom(shellSrc, offer, 1600);
      expect(body.contains('_rewrapRouteUp()'), isTrue,
          reason: 'every cover flip resets the per-State flag; only the route '
              'check survives a remount',);
    });
  });
}
