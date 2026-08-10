import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The onboarding funnel produced a dead account, and every step of it was a
/// state the user could enter but not leave. These pin the escapes so they
/// cannot quietly disappear again.
///
/// Source-level rather than behavioural: reaching these screens needs a live
/// Supabase session, so a widget test would assert against mocks rather than
/// against the thing that broke. What actually broke was structural — a code
/// held only in widget state, and screens with no way out — and that is exactly
/// what a source check can hold in place.
void main() {
  String read(String path) => File(path).readAsStringSync();

  // A method's closing brace: newline, two spaces, brace.
  const closeBrace = '\n  }';

  final couplePage = read('lib/features/auth/couple_page.dart');
  final signIn = read('lib/features/auth/sign_in_page.dart');
  final home = read('lib/features/home/home_screen.dart');
  final repo = read('lib/core/data/supabase_repository.dart');

  group('the invite code survives leaving the app', () {
    test('the couple page recovers a live invite from the server', () {
      // Sharing a code REQUIRES leaving the app, which drops the disguise cover
      // over everything and destroys this screen. Held only in widget state,
      // the code was gone at exactly the moment it had been used.
      // Must be CALLED from initState, not merely defined. A recovery function
      // nobody invokes is the same bug with extra steps — and an earlier
      // version of this test passed with the call deleted.
      final init = couplePage.substring(couplePage.indexOf('void initState()'));
      final body = init.substring(0, init.indexOf(closeBrace));
      expect(body, contains('_restoreInvite'),
          reason: 'the code must be recovered when the screen is rebuilt, '
              'because the screen holding it does not survive the share',);
      expect(couplePage, contains('activePairingInvite'));
    });

    test('the repository can fetch a live invite at all', () {
      expect(repo, contains('activePairingInvite'));
      // Must exclude consumed and expired rows, or it hands back a code that
      // will fail when the partner types it.
      final fn = repo.substring(repo.indexOf('activePairingInvite'));
      final body = fn.substring(0, fn.indexOf('\n  }'));
      expect(body, contains('consumed_at'));
      expect(body, contains('expires_at'));
    });
  });

  group('no screen in the funnel is a trap', () {
    test('the couple page has a sign out', () {
      // The router sends anyone without a couple back to /couple from every
      // path, so without this there is no exit and no route to Settings.
      expect(couplePage, contains('Future<void> _signOut'),
          reason: '/couple is inescapable by design of the redirect',);
      // And wired to something tappable, not just present.
      expect(couplePage, contains('onPressed: _loading ? null : _signOut'));
    });

    test('waiting for a partner offers the code and a new one', () {
      // A couple exists, so the router will never route back to pairing. If the
      // code is lost here, the account is finished.
      expect(home, contains('_WaitingForPartner'));
      final w = home.substring(home.indexOf('class _WaitingForPartnerState'));
      final init = w.substring(w.indexOf('void initState()'));
      expect(init.substring(0, init.indexOf(closeBrace)), contains('_load'),
          reason: 'the code must be fetched when the state appears',);
      expect(w, contains('activePairingInvite'),
          reason: 'must be able to show the code again',);
      expect(w, contains('createPairingInvite'),
          reason: 'must be able to mint a new one when the old has expired',);
    });
  });

  group('a forgotten password is not a lost account', () {
    test('sign in offers a reset', () {
      expect(signIn, contains('_forgotPassword'));
      expect(repo, contains('resetPasswordForEmail'));
    });

    test('the reset does not disclose whether an account exists', () {
      // Otherwise this screen becomes a way to enumerate who is registered.
      final fn = signIn.substring(signIn.indexOf('_forgotPassword'));
      final body = fn.substring(0, fn.indexOf('\n  @override'));
      expect(body, contains('If '),
          reason: 'the confirmation must read the same either way',);
      expect(body.contains('catch'), isTrue,
          reason: 'a failure must not be reported differently from a success',);
    });
  });
}
