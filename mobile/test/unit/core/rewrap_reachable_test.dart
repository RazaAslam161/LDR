import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// /rewrap was unreachable while unpaired, and the reason was written down:
/// "Below the funnel because an account with no partner has nobody to ask."
/// 20260826180000 made that false — a dissolved couple inside its window has
/// two members who can still run the ceremony — so the funnel now carves out
/// one exception.
///
/// The exception is the dangerous part, not the fix. Two ways to get it wrong:
///
///   · Hoist the keyless gate above needsCouple. Smaller diff, wrong: a fresh
///     keyless account that never had a couple is then sent to /rewrap with
///     nobody to ask, which is the deadlock the old ordering avoided.
///   · Redirect TO /rewrap rather than allowing it. That cuts an unpaired
///     account off from /couple, where sign-out and the permanent erase live —
///     the trap class onboarding_escape_test exists for.
void main() {
  String read(String path) => File(path).readAsStringSync();

  String code(String src) => src
      .split('\n')
      .where((l) =>
          !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'),)
      .join('\n');

  late String router;
  setUpAll(() => router = code(read('lib/core/app/router.dart')));

  test('the allowance is conditional on there being somebody to ask', () {
    final gate = router.indexOf('if (needsCouple)');
    expect(gate, greaterThan(-1), reason: 'the couple funnel has gone');
    final end = router.indexOf('needsRole', gate);
    final region = router.substring(gate, end);

    expect(region.contains("'/rewrap'"), isTrue,
        reason: 'the ceremony is unreachable while unpaired again',);
    expect(region.contains('CryptoCore.keyless.value'), isTrue,
        reason: 'the allowance must require that this phone actually cannot '
            'read anything',);
    expect(region.contains('SeveranceState.held.value != null'), isTrue,
        reason: 'without this a fresh keyless account with no history is let '
            'through to a ceremony nobody can answer',);
  });

  test('the funnel allows /rewrap, it never redirects to it', () {
    final gate = router.indexOf('if (needsCouple)');
    final end = router.indexOf('needsRole', gate);
    final region = router.substring(gate, end);
    expect(region.contains("return '/rewrap'"), isFalse,
        reason: 'redirecting an unpaired account to /rewrap cuts it off from '
            '/couple, where sign-out and the permanent erase are',);
    expect(region.contains("return path == '/couple' ? null : '/couple';"),
        isTrue,
        reason: 'every other unpaired path must still land on /couple',);
  });

  test('the keyless gate is still BELOW the couple funnel', () {
    // Hoisting it is the tempting smaller change and it reintroduces the
    // deadlock for accounts that never had a partner.
    final couple = router.indexOf('final needsCouple');
    final keyless = router.indexOf('if (CryptoCore.keyless.value && path !=');
    expect(couple, greaterThan(-1));
    expect(keyless, greaterThan(couple),
        reason: 'the unconditional keyless redirect must stay below the couple '
            'funnel; only the carve-out above may run earlier',);
  });

  test('the redirect observes everything it reads', () {
    // A redirect that reads a notifier the router does not listen to is
    // evaluated once and never re-run, so the route silently never opens.
    final refresh = router.substring(
        router.indexOf('refreshListenable'), router.indexOf('observers:'),);
    for (final source in [
      '_SessionListenable',
      'CryptoCore.keyless',
      'TermsGate.accepted',
      'SeveranceState.held',
    ]) {
      expect(refresh.contains(source), isTrue,
          reason: '$source is read by the redirect but not observed',);
    }
  });

  test('the ceremony is pushed, so it keeps a way back', () {
    final sheet = code(read('lib/features/safety/reconnect_sheet.dart'));
    expect(sheet.contains("context.push('/rewrap')"), isTrue,
        reason: 'the entry point has gone',);
    expect(sheet.contains("context.go('/rewrap')"), isFalse,
        reason: 'go replaces the stack and strands whoever arrives',);
  });

  test('the ceremony screen resolves a couple without a session couple', () {
    // This is what made the route usable rather than merely open. All three
    // paths read a resolver that falls back to SeveranceState; none may go
    // back to reading session.couple directly.
    final screen = code(read('lib/features/auth/rewrap_screen.dart'));
    expect(screen.contains('SeveranceState.held.value?.coupleId'), isTrue,
        reason: 'the screen cannot name a dissolved couple again',);
    expect(screen.contains('ref.read(sessionProvider).couple;'), isFalse,
        reason: 'a direct read of session.couple bypasses the fallback',);
  });

  test('the claim resolves its peer from the answered row', () {
    // couple_members is own-rows-only on purpose, so while unpaired nothing
    // else names the other person. wrapped_by is written by the same UPDATE as
    // wrapped_keys, so it is never null when there is anything to claim.
    final rewrap = code(read('lib/core/data/partner_rewrap.dart'));
    expect(rewrap.contains("row['wrapped_by'] as String?"), isTrue,
        reason: 'claim must take the peer off the row it already reads',);
    final screen = code(read('lib/features/auth/rewrap_screen.dart'));
    expect(screen.contains('_claim(partner.id)'), isFalse,
        reason: 'session.partner is null for exactly the case this fixes',);
  });
}
