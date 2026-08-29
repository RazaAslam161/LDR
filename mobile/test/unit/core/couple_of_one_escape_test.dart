import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A couple of ONE was a dead end with no destructive-free way out.
///
/// Both partners pressing "Create & get a code" is the obvious move when
/// neither was told who goes first, and it left each of them owning a couple
/// with nobody in it. From the next relaunch the funnel read that as "paired"
/// and swept '/couple' — the only route in the app carrying a redeem field, and
/// the target of the invite deep link — to '/app' forever.
///
/// Source-level, like its neighbour onboarding_escape_test.dart and for the
/// same reason: the redirect reads a live Supabase session, so a widget test
/// would assert against a mock rather than against the funnel that broke. What
/// broke was structural — an allowance that was not there, and a screen whose
/// only actions were copy and re-mint.
void main() {
  String read(String path) => File(path).readAsStringSync();

  final router = read('lib/core/app/router.dart');
  final home = read('lib/features/home/home_screen.dart');
  final waiting =
      home.substring(home.indexOf('class _WaitingForPartnerState'));

  group('a couple of one can still reach the redeem field', () {
    test('the router leaves /couple open while there is no partner', () {
      const allowance = "path == '/couple' && session.partner == null";
      expect(router, contains(allowance),
          reason: 'the only redeem field lives on /couple, so a member of a '
              'couple of one must be able to open it',);
      // Before the sweep, or it never runs.
      expect(router.indexOf(allowance),
          lessThan(router.indexOf("          path == '/couple' ||")),
          reason: 'the sweep returns /app and would win',);
    });

    test('a genuinely paired user is still swept off /couple', () {
      // The allowance must not be bought by deleting the sweep entry — that
      // would put a paired couple back on the pairing screen.
      expect(router, contains("          path == '/couple' ||"));
    });

    test('the waiting screen offers a way to the redeem field', () {
      // The funnel never routes a couple-holder to /couple, so this screen is
      // where the trip has to start for anyone who does not hold a deep link.
      expect(waiting, contains("context.go('/couple')"),
          reason: 'copy and re-mint are not an escape when the other partner '
              'is holding their own code',);
    });
  });

  group('the waiting screen reports what failed', () {
    test('neither pairing call swallows its error', () {
      // Both were `catch (_)` returning to the exact prior state: a control
      // that visibly does nothing on the sole surface that can hand the code
      // over.
      expect(waiting.contains('catch (_)'), isFalse,
          reason: 'a swallowed failure here is indistinguishable from '
              'having no invite at all',);
      expect(waiting, contains('_error = friendlyAuthError(e)'));
    });

    test('"still live" is not claimed over a code we do not have', () {
      final line = waiting.indexOf('They need this code. It is still live.');
      expect(line, greaterThan(-1));
      // The guard has to sit above it; unconditional, it printed directly over
      // "No live code right now."
      expect(waiting.substring(0, line), contains('if (code != null)'));
    });
  });
}
