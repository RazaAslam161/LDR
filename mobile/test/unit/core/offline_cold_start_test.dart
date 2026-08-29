import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/models.dart';

/// A cold start in airplane mode used to end on the blank new-user form: a
/// profile fetch that threw and one that found no row both left the profile
/// null, the router reads null as "needs onboarding", and that form's submit
/// upserts over the user's real name, timezone and date of birth the moment
/// connectivity returns. These pin the two halves of the fix: the state can
/// tell a failure from a no-row answer, and the router sends them to
/// different places.
///
/// The router half is source-level, for the same reason as
/// onboarding_escape_test.dart: running the redirect needs a live Supabase
/// session, and what has to hold is structural — which check runs first, and
/// where each state is sent.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('a failed load and a missing row are different states', () {
    test('a thrown fetch is a failure, not a new account', () {
      const failed = SessionState(loading: false, error: 'TimeoutException');
      expect(failed.profileLoadFailed, isTrue);
    });

    test('a server that answered "no row" is a new account, not a failure',
        () {
      const noRow = SessionState(loading: false);
      expect(noRow.profileLoadFailed, isFalse,
          reason: 'only a definite no-row answer may lead to onboarding',);
    });

    test('a session that already has a profile is never the failure state',
        () {
      // A refresh can fail long after a launch succeeded. The user keeps the
      // profile they have instead of being bounced out of the app.
      final loaded = SessionState(
        loading: false,
        profile: Profile(
          id: 'u1',
          displayName: 'A',
          timezone: 'UTC',
          presenceStatus: PresenceStatus.free,
          createdAt: DateTime(2026),
        ),
        error: 'TimeoutException',
      );
      expect(loaded.profileLoadFailed, isFalse);
    });

    test('starting a retry clears the previous failure', () {
      // loadProfile opens with copyWith(loading: true); copyWith drops the
      // error unless one is passed, so the failure cannot outlive the attempt
      // that follows it — a no-row answer after a retry reads as new account,
      // never as the failure that preceded it.
      const failed = SessionState(loading: false, error: 'TimeoutException');
      expect(failed.copyWith(loading: true).profileLoadFailed, isFalse);
    });
  });

  group('the router sends the two states to different screens', () {
    final router = read('lib/core/app/router.dart');

    test('a failed load is held on /offline, above the welcome check', () {
      expect(router, contains('profileLoadFailed'));
      // ABOVE the funnel's null-profile check, or the failure is swept to
      // /welcome before it is ever consulted.
      expect(router.indexOf('profileLoadFailed'),
          lessThan(router.indexOf('needsProfile')),);
      expect(router, contains("return path == '/offline' ? null : '/offline'"));
    });

    test('a recovered session is swept off /offline into the app', () {
      // The final sweep list is the only thing that moves a fully-set-up
      // session off this screen; the screen itself never navigates.
      final sweep = router.substring(router.indexOf('if (isAuthRoute ||'));
      expect(sweep.substring(0, sweep.indexOf("return '/app';")),
          contains("path == '/offline'"),);
    });
  });

  group('the offline screen can actually get the user out', () {
    final screen = read('lib/features/auth/offline_screen.dart');

    test('retry goes through the same loadProfile the launch used', () {
      // Sliced out of _retry, not searched for across the file: the token also
      // appears in _signOut's doc comment three lines below the only real
      // call, so a whole-file contains() stayed green against a _retry gutted
      // to nothing — the false pass chat_selection_test.dart already records.
      // Same slice account_management_test takes of _signOut on this screen.
      final start = screen.indexOf('void _retry()');
      expect(start, greaterThan(-1), reason: '_retry was renamed or removed');
      final fn = screen.substring(start);
      expect(fn.substring(0, fn.indexOf('\n  }')), contains('loadProfile'),
          reason: 'a _retry that calls nothing leaves the screen a dead end '
              'until the user finds sign-out',);
    });

    test('it retries on its own, not only on the button', () {
      // Connectivity comes back outside the app, so returning to it must
      // retry unprompted — and on the disguised channel the cover replaces
      // the widget tree, so the screen mounts AFTER resumed has fired and
      // must also retry on mount.
      expect(screen, contains('AppLifecycleState.resumed'));
      expect(screen, contains('addPostFrameCallback'));
    });
  });
}
