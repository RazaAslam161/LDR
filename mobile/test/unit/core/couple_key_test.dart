import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/couple_key.dart';

/// `CoupleKey.ensure` is the chat path's only route to the couple key, and its
/// whole contract is that it CANNOT break chat.
///
/// Chat sends and renders today with no key at all, on every build already in
/// the field. If this ever throws — a partner mid-setup, a corrupt key column,
/// no network — it takes `_init()` down with it and the conversation does not
/// paint. So the contract is: answer false, never throw.
///
/// Coverage limit, stated rather than implied: the paths that reach
/// SupabaseRepository and the platform keystore are not exercised here, for the
/// same reason crypto_core_test.dart documents — a plain unit test has neither.
/// What is covered is the guard that runs FIRST on every chat open, which is
/// the case that actually happens on a phone before pairing finishes.
void main() {
  setUp(CoupleKey.resetForTest);

  test('no session at all is false, not an exception', () async {
    // The literal first chat open of a fresh install: profile and partner are
    // still loading. This must not reach the network and must not throw.
    expect(await CoupleKey.ensure(const SessionState()), isFalse);
  });

  test('a signed-in user with no partner yet is false', () async {
    // Paired-with-nobody is an ordinary state, not an error: half of onboarding
    // is spent here. It must be a quiet false so nothing logs an error and
    // nothing blocks.
    expect(
      await CoupleKey.ensure(const SessionState(loading: false)),
      isFalse,
    );
  });

  test('ensure is safe to call repeatedly', () async {
    // _init() runs on every chat open and the shell can mount the screen more
    // than once, so this is called far more often than it does work.
    for (var i = 0; i < 5; i++) {
      expect(await CoupleKey.ensure(const SessionState()), isFalse);
    }
  });
}
