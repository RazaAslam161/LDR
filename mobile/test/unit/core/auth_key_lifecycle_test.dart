import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The three decisions that stand between a couple and a silently unreadable
/// history, none of which had a test before this file.
///
/// Only [strandedAfterRestore] is reachable directly — the other two live
/// behind FlutterSecureStorage and local_auth, which a plain unit test cannot
/// reach. Those are pinned against the source instead, and a source pin is
/// honestly weaker than a behavioural test: it proves the guard is still
/// written, not that it still fires. It is here because the alternative for
/// this path is nothing at all, and because both regressions are a one-line
/// edit that reads perfectly innocent in review.
void main() {
  group('strandedAfterRestore', () {
    test('a brand-new account is NOT stranded', () {
      // The regression that walled every new user: the X25519 seed is minted
      // lazily, so a first-ever sign-in has none. That is not a wiped keystore,
      // and reading it as one sent a three-minute-old account into a ceremony
      // asking its partner to send back a key neither of them ever had.
      expect(
        strandedAfterRestore(
          alreadyKeyless: false,
          hasSeed: false,
          hadPriorIdentity: false,
        ),
        isFalse,
      );
    });

    test('no seed but a published key IS stranded', () {
      // The real reinstall: Android wiped the keystore, and the account has an
      // identity on the server this device can no longer produce.
      expect(
        strandedAfterRestore(
          alreadyKeyless: false,
          hasSeed: false,
          hadPriorIdentity: true,
        ),
        isTrue,
      );
    });

    test('a phone holding its seed is never stranded by a failed lookup', () {
      // _hadPriorIdentity reports false when it cannot reach the server, so
      // this is also the offline case. A device that holds its key must not be
      // walled by one bad response.
      for (final prior in [true, false]) {
        expect(
          strandedAfterRestore(
            alreadyKeyless: false,
            hasSeed: true,
            hadPriorIdentity: prior,
          ),
          isFalse,
          reason: 'hadPriorIdentity=$prior',
        );
      }
    });

    test('an existing keyless mark survives every other input', () {
      // Including `deferred`, which isKeyless() still reports as true: tapping
      // past the offer does not put the key back on the phone.
      for (final seed in [true, false]) {
        for (final prior in [true, false]) {
          expect(
            strandedAfterRestore(
              alreadyKeyless: true,
              hasSeed: seed,
              hadPriorIdentity: prior,
            ),
            isTrue,
            reason: 'hasSeed=$seed hadPriorIdentity=$prior',
          );
        }
      }
    });
  });

  group('source pins', () {
    String read(String path) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: 'moved or renamed: $path');
      return f.readAsStringSync();
    }

    test('signUp binds from the response, never from currentUser', () {
      // gotrue only swaps the stored session when the reply carries one, and
      // with email confirmation on it never does. Reading currentUser here
      // bound key storage to whoever was signed in BEFORE the call and sealed
      // their seed under a stranger's password.
      final src = read('lib/core/data/supabase_repository.dart');
      final body = src.substring(
        src.indexOf('static Future<void> signUp('),
        src.indexOf('static Future<void> signIn('),
      );
      // The call, not the word — the comment above the fix names it too.
      expect(body.contains('auth.currentUser'), isFalse,
          reason: 'signUp must not read currentUser:\n$body',);
      expect(body.contains('res.session == null'), isTrue, reason: body);
    });

    test('answer() refuses from a keyless phone before exporting a chain', () {
      // A keyless phone HAS a key — the stand-in minted on first use — so the
      // emptiness check passes and it hands over 32 bytes that open nothing.
      final src = read('lib/core/data/partner_rewrap.dart');
      final body = src.substring(src.indexOf('static Future<int> answer('));
      final guard = body.indexOf('CryptoCore.isKeyless()');
      final export = body.indexOf('exportKeyChainBytes');
      expect(guard, isNot(-1), reason: 'the keyless guard is gone:\n$body');
      expect(guard, lessThan(export),
          reason: 'the guard must run before the chain is exported',);
    });

    test('answer() refuses by default and only a human may override', () {
      // The override exists because the mark is not reliable enough to convict
      // on: builds 27-37 set it on every new account, so a phone carrying it
      // may be the only one that CAN answer. It must still default to refusing,
      // or the guard is decorative.
      final src = read('lib/core/data/partner_rewrap.dart');
      expect(src.contains('bool readableConfirmed = false'), isTrue,
          reason: 'the override must default to refusing',);
      expect(src.contains('isKeyless() && !readableConfirmed'), isTrue,
          reason: 'the guard no longer consults the override',);
      // And the only caller must pass a value it got from the human, never a
      // literal true.
      final screen = read('lib/features/auth/rewrap_screen.dart');
      expect(screen.contains('readableConfirmed: true'), isFalse,
          reason: 'the ceremony hard-codes the override',);
      expect(screen.contains('readableConfirmed: _readableConfirmed'), isTrue);
    });

    test('sign-in mints a seed only on two positive answers', () {
      // Minting on a guess produces a stand-in, and the backup on the next line
      // seals it over the row still holding the couple's real key.
      final src = read('lib/core/data/supabase_repository.dart');
      expect(
        src.contains(
          'if (!stranded && published == false && await KeyEscrow.isMissing())',
        ),
        isTrue,
        reason: 'the mint guard lost one of its two positive signals',
      );
    });

    test('an unknown published-identity defaults to LOST, never to new', () {
      // The asymmetry is the whole argument. Walling someone who was fine costs
      // a screen they can tap past; clearing someone who was stranded costs the
      // couple's history — they are never routed to the ceremony, mint a
      // stand-in, and the next sign-in escrows it over the real row. `?? false`
      // shipped that for one turn.
      final src = read('lib/core/data/supabase_repository.dart');
      expect(src.contains('published ?? false'), isFalse,
          reason: 'signIn treats a failed lookup as a brand-new account',);
      expect(src.contains('_publishedIdentity() ?? false'), isFalse,
          reason: 'updatePassword treats a failed lookup as a new account',);
      expect(src.contains('published ?? true'), isTrue);
    });

    test('an incoming intent no longer raises the cover', () {
      // MainActivity is exported with a BROWSABLE filter, so any app or web
      // page can send tethered://auth-callback. Only the auth stream is
      // evidence that a real token was redeemed.
      final src = read('lib/main.dart');
      final handler = src.substring(
        src.indexOf('void _handleLink(Uri uri)'),
        src.indexOf('void dispose()'),
      );
      expect(handler.contains('pendingAuthLink'), isFalse,
          reason: 'pendingAuthLink is raised from an intent again:\n$handler',);
      expect(src.contains('void _watchAuthLinkRedemption()'), isTrue);
    });
  });

  group('passwordChangeOutcome', () {
    test('no key on this device and none ever published is settled', () {
      // Reset before the account ever opened a screen that mints a seed. There
      // is nothing to re-seal and nothing was lost; this used to mark the
      // account keyless and route it into a partner ceremony for a couple that
      // had written nothing.
      expect(
        passwordChangeOutcome(
          hasSeed: false,
          publishedIdentity: false,
          escrowWritten: false,
        ),
        PasswordChangeOutcome.settled,
      );
    });

    test('no key but a published identity is keyless', () {
      expect(
        passwordChangeOutcome(
          hasSeed: false,
          publishedIdentity: true,
          escrowWritten: false,
        ),
        PasswordChangeOutcome.keyless,
      );
    });

    test('a seed here with the escrow re-sealed is settled', () {
      expect(
        passwordChangeOutcome(
          hasSeed: true,
          publishedIdentity: false,
          escrowWritten: true,
        ),
        PasswordChangeOutcome.settled,
      );
    });

    test('a seed here with the re-seal refused is escrowStale', () {
      // The case the screen printed "Password updated 💛" over: the escrow is
      // still locked with the password they just replaced, so this phone is now
      // the only copy of the couple's key and nobody said so.
      expect(
        passwordChangeOutcome(
          hasSeed: true,
          publishedIdentity: true,
          escrowWritten: false,
        ),
        PasswordChangeOutcome.escrowStale,
      );
    });
  });

  group('friendlyAuthError', () {
    test('a rate limit says wait, never "try again"', () {
      // The generic ending advises retrying now, which is the one action that
      // re-extends the window. GoTrue's shared mailer allows one reset a minute
      // per address, so this is an ordinary outcome, not an edge case.
      for (final e in [
        const AuthException('x', statusCode: '429'),
        const AuthException('x', code: 'over_email_send_rate_limit'),
        const AuthException('x', code: 'over_request_rate_limit'),
      ]) {
        final msg = friendlyAuthError(e);
        expect(msg.toLowerCase(), contains('wait'), reason: '$e -> $msg');
        expect(msg, isNot(contains('Something went wrong')), reason: msg);
      }
    });

    test('a weak password names the length the forms ask for', () {
      expect(
        friendlyAuthError(const AuthException('x', code: 'weak_password')),
        contains('8'),
      );
    });

    test('the length fallback says 8, matching every field', () {
      // It said six while both password fields and NewPasswordPage said eight,
      // so the one message shown after a refusal told the user to do something
      // that would be refused again.
      final msg = friendlyAuthError(
        Exception('Password should be at least 6 characters'),
      );
      expect(msg, contains('8'));
      expect(msg, isNot(contains('6')));
    });

    test('an unreachable server is matched by type, not by wording', () {
      // The old check matched the bare substring `connection`, so a Postgres
      // pooler error told people to check their phone's clock.
      expect(
        friendlyAuthError(AuthRetryableFetchException(message: 'x')),
        contains('internet'),
      );
    });

    test('a duplicate signup never says the address is taken', () {
      // SignUpPage sends every submission to the same "Check your inbox" state
      // so the form cannot be fed addresses to learn who has an account on a
      // private couples app. This map used to undo that in one line, the
      // moment GoTrue raised instead of answering with a success shape — which
      // is what it does whenever email confirmation is turned off, a dashboard
      // setting no code here controls.
      for (final e in [
        Exception('User already registered'),
        const AuthException(
          'user already registered',
          code: 'user_already_exists',
        ),
        const AuthException(
          'Email address already in use',
          code: 'email_exists',
        ),
      ]) {
        final msg = friendlyAuthError(e).toLowerCase();
        for (final leak in [
          'already',
          'exists',
          'registered',
          'taken',
          'in use',
          'sign in instead',
        ]) {
          expect(msg, isNot(contains(leak)), reason: '$e -> $msg');
        }
      }
    });
  });
}
