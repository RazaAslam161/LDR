import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Account management, pinned at the source level like onboarding_escape_test:
/// reaching any of these paths needs a live Supabase session, so a widget test
/// would assert against mocks rather than against the shapes that matter — a
/// sign-out scope that must exclude this device, an email change that must not
/// pretend to be instant, an offline exit that must survive the dead network
/// it exists for, and profile writes that now throw where they used to no-op.
void main() {
  String read(String path) => File(path).readAsStringSync();

  // A method's closing brace: newline, two spaces, brace.
  const closeBrace = '\n  }';

  final repo = read('lib/core/data/supabase_repository.dart');
  final settings = read('lib/features/settings/settings_screen.dart');
  final offline = read('lib/features/auth/offline_screen.dart');

  group('email change', () {
    test('the repository can ask for one, through the hosted callback', () {
      final start = repo.indexOf('static Future<void> changeEmail');
      expect(start, greaterThanOrEqualTo(0));
      final body = repo.substring(start);
      final fn = body.substring(0, body.indexOf(closeBrace));
      expect(fn, contains('UserAttributes(email:'));
      // Both confirmation mails must land on the hosted handoff page like
      // every other auth mail — omitting the redirect falls back to the
      // project's Site URL, which is how confirmation links once opened
      // "localhost refused to connect" on a phone.
      expect(fn, contains('authCallbackUrl'));
    });

    test('settings offers it and says both mailboxes must confirm', () {
      expect(settings, contains('onTap: _changeEmail'),
          reason: 'a repository method nobody can reach is not a feature',);
      final start = settings.indexOf('Future<void> _changeEmail');
      final body = settings.substring(start);
      final fn = body.substring(0, body.indexOf(closeBrace));
      expect(fn, contains('both'),
          reason: 'the change stalls until BOTH links are opened; a dialog '
              'that reads as one link makes the feature look broken',);
      expect(fn.contains('catch'), isTrue,
          reason: 'a refused change must surface, not vanish');
    });
  });

  group('sign out of other devices', () {
    test('the repository revokes the others and ONLY the others', () {
      final start = repo.indexOf('static Future<void> signOutOtherDevices');
      expect(start, greaterThanOrEqualTo(0));
      final body = repo.substring(start);
      final fn = body.substring(0, body.indexOf(closeBrace));
      // local or global scope here signs out THIS device too — the person
      // reacting to a lost phone would lock themselves out with the remedy.
      expect(fn, contains('scope: SignOutScope.others'));
    });

    test('settings offers it behind a confirm that surfaces failure', () {
      expect(settings, contains('onTap: _signOutOtherDevices'));
      final start = settings.indexOf('Future<void> _signOutOtherDevices');
      final body = settings.substring(start);
      final fn = body.substring(0, body.indexOf(closeBrace));
      expect(fn, contains('showDialog'),
          reason: 'revoking sessions is not a single-tap action');
      expect(fn.contains('catch'), isTrue,
          reason: 'devices still signed in must not be reported signed out');
    });
  });

  group('the offline screen is not a trap', () {
    test('it has a sign out wired to something tappable', () {
      // The router holds a failed profile load on /offline from every path,
      // and loadProfile fails for non-network reasons too — without an exit,
      // those accounts wait forever behind copy blaming the connection.
      expect(offline, contains('Future<void> _signOut'));
      expect(offline, contains('onPressed: _signOut'));
    });

    test('signing out survives the dead network the screen exists for', () {
      final start = offline.indexOf('Future<void> _signOut');
      final body = offline.substring(start);
      final fn = body.substring(0, body.indexOf(closeBrace));
      expect(fn.contains('catch'), isTrue,
          reason: 'the server-side revoke needs the network this screen '
              'exists for lacking; an unhandled throw strands the funnel',);
      expect(fn, contains('debugPrint'),
          reason: 'the revoke failure is logged, never swallowed');
    });
  });

  group('settings does not report a save that did not happen', () {
    test('every profile write in settings is inside a try', () {
      // setAvatarUrl, setGender and updateMyProfile throw StateError when
      // signed out — they used to no-op silently while the screen toasted
      // 'Updated'. Every call site must catch, or the throw lands unhandled
      // behind a toast that already lied.
      for (final call in [
        'SupabaseRepository.setAvatarUrl',
        'SupabaseRepository.setGender',
        'SupabaseRepository.updateMyProfile',
      ]) {
        var from = settings.indexOf(call);
        expect(from, greaterThanOrEqualTo(0),
            reason: '$call has no call site in settings — if it moved, '
                'this test must follow it',);
        while (from != -1) {
          final before = settings.substring(0, from);
          final methodStart = before.lastIndexOf('  Future<void> _');
          final lastTry = before.lastIndexOf('try {');
          // Inside the current method, and still open: a try whose catch has
          // already appeared before the call is a different, finished block.
          expect(lastTry, greaterThan(methodStart),
              reason: '$call at offset $from is not wrapped',);
          expect(lastTry, greaterThan(before.lastIndexOf('catch')),
              reason: '$call at offset $from sits after its try closed',);
          from = settings.indexOf(call, from + 1);
        }
      }
    });
  });
}
