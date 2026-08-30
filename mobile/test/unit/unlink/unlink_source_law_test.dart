import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The ritual's structural laws, source-read where behaviour needs a
/// database or a platform to exercise.
void main() {
  final shell =
      File('lib/features/shell/app_shell.dart').readAsStringSync();
  final repo =
      File('lib/features/unlink/unlink_repository.dart').readAsStringSync();
  final router = File('lib/core/app/router.dart').readAsStringSync();
  final main_ = File('lib/main.dart').readAsStringSync();
  final unlinkDir = Directory('lib/features/unlink')
      .listSync()
      .whereType<File>()
      .map((f) => f.readAsStringSync())
      .join('\n');

  test('the ritual takes the app away through the router, not a banner', () {
    // The banner and the AppShell landing latch are GONE, and both have to
    // stay gone. They were the shipped design and they are the reason the
    // whole mechanism read as "nothing happens": a 4mm strip you can ignore,
    // plus a push that fires once per ceremony and is dismissible forever
    // after. Two mechanisms racing for the same decision is also how the
    // landing ended up depending on which of three callers won.
    expect(main_.contains('UnlinkBanner'), isFalse,
        reason: 'the banner is not a ritual; the router gate replaced it',);
    // The identifier, not the stored key: the comment that records WHY the
    // latch went names the old key on purpose, and a law that fires on its
    // own explanation teaches the next person to delete the explanation.
    expect(shell.contains('_unlinkLandedKey'), isFalse,
        reason: 'a dismissible latch cannot hold a takeover',);
    expect(router.contains('UnlinkState.current'), isTrue,
        reason: 'without it in refreshListenable the gate is decided once, '
            'against whatever was loaded when the router was built',);
    expect(router.contains("return '/unlink';"), isTrue,
        reason: 'the redirect IS the takeover',);
  });

  test('the gate never closes the exits', () {
    // Assertion #4 of 20260829120000, on the client side: leaving can be
    // slowed by the ceremony you chose, never blocked by machinery someone
    // else controls. Play policy needs the account route reachable too, and
    // a ritual that holds your photographs is a threat rather than a pause.
    final at = router.indexOf('bool unlinkAllows(');
    expect(at, greaterThan(-1));
    final body = router.substring(at, at + 900);
    for (final path in [
      '/app/settings/export',
      '/app/settings/account',
      '/rewrap',
      '/call',
    ]) {
      expect(body.contains(path), isTrue,
          reason: '$path must stay reachable inside the ritual',);
    }
  });

  test('the ritual leaves no chat door — the note is the channel', () {
    // Removed on the owner's call, and correctly. Chat was allowed to the
    // partner and refused to the initiator, so the partner's button opened a
    // room the other person could not enter and the messages went nowhere
    // until the ritual was already over. The note reaches the screen that
    // matters; a second channel that does not is worse than none.
    expect(router.contains('/unlink/chat'), isFalse,
        reason: 'the chat door is back, in the shape that did not work',);
    // The page file's absence is deliberately NOT asserted by name here:
    // repo_hygiene's "every source path a test names actually exists" law
    // scans tests for paths and fails on one that is gone, which is the whole
    // point of deleting it. The route and the button below are what actually
    // make it unreachable, and neither can be restored without failing this.
    final screen =
        File('lib/features/unlink/unlink_screen.dart').readAsStringSync();
    expect(screen.contains('Talk to them'), isFalse);
  });

  test('the shell listens through the managed channel, never hand-rolled',
      () {
    final at = shell.indexOf("channelName: 'unlink:");
    expect(at, greaterThan(-1));
    expect(
        shell
            .substring(at - 300, at)
            .contains('ManagedSubscription.start'),
        isTrue,
        reason: 'a raw channel dies silently on the first reconnect',);
    expect(shell.contains("table: 'couple_unlink'"), isTrue);
  });

  test('realtime events are signals — the row is always refetched', () {
    // The handler must reload over PostgREST, never parse the payload:
    // realtime serializes bytea differently and the note would corrupt.
    final at = shell.indexOf('Future<void> _onUnlinkChanged()');
    expect(at, greaterThan(-1));
    final body = shell.substring(at, at + 1200);
    expect(body.contains('UnlinkState.load()'), isTrue);
    expect(body.contains('payload'), isFalse);
  });

  test('every kind the server can send has a branch on the client', () {
    // A serialization boundary, and it failed the first time it was crossed.
    // reach-notify gained three unlink kinds; the client knew one. The other
    // three did not go quiet — reach_notifications' dispatch defaults to REACH,
    // so they would have fired the app's max-importance alert, during a
    // breakup, carrying an id belonging to something else. Its own comment
    // says so, two lines below the branch that was missing.
    //
    // The kinds are read from the EDGE FUNCTION rather than listed here, so
    // adding a fifth to the server and forgetting the handset fails this.
    final fn = File('../supabase/functions/reach-notify/index.ts')
        .readAsStringSync();
    final union = fn.substring(
      fn.indexOf('const kind:'),
      fn.indexOf('payload.kind ?? payload.type'),
    );
    final kinds = RegExp('"(unlink[a-z_]*)"')
        .allMatches(union)
        .map((m) => m[1]!)
        .toSet();
    expect(kinds.length, greaterThanOrEqualTo(4),
        reason: 'the unlink kinds could not be read out of reach-notify',);

    final fcm = File('lib/core/services/fcm_service.dart').readAsStringSync();
    final notif =
        File('lib/core/services/reach_notifications.dart').readAsStringSync();
    for (final kind in kinds) {
      expect(fcm.contains("'$kind'"), isTrue,
          reason: 'fcm_service has no branch for $kind, so it falls through '
              'to the Reach overlay',);
      expect(notif.contains("'$kind'"), isTrue,
          reason: 'reach_notifications has no branch for $kind, so it posts '
              'the max-importance Reach alert instead of the quiet channel',);
    }
  });

  test('exactly one AAD builder', () {
    expect('unlink_note:'.allMatches(repo).length, 1,
        reason: 'two spellings of the AAD is how seal and open drift apart',);
  });

  test('the feature sends nothing itself — the DB trigger owns the telling',
      () {
    expect(unlinkDir.contains('FcmService'), isFalse);
    expect(unlinkDir.contains('http_post'), isFalse);
  });

  test('execution happens on human presence, from either phone', () {
    // The teardown moved out of AppShell so both drivers share one copy —
    // see the law below for why there had to be two.
    final completion =
        File('lib/features/unlink/unlink_completion.dart').readAsStringSync();
    expect(completion.contains('UnlinkRepository.execute()'), isTrue);
    final execAt = completion.indexOf('UnlinkRepository.execute()');
    final endAt = completion.indexOf('endCouple(');
    final loadAt = completion.indexOf('loadProfile()');
    expect(endAt, greaterThan(execAt));
    expect(loadAt, greaterThan(endAt),
        reason: "the pinned teardown order, with the RPC in leaveCouple's "
            'seat',);
  });

  test('the screen can finish the ceremony without the shell', () {
    // The defect this pins was created by the takeover itself. The router gate
    // redirects to /unlink, which UNMOUNTS AppShell — and AppShell held the
    // realtime subscription, the push drain and the deadline check. A phone
    // parked on the ritual at the deadline would have shown a stale row for
    // ever, and a Re-link from the far side would never have arrived: the
    // takeover disabled its own completion.
    final screen =
        File('lib/features/unlink/unlink_screen.dart').readAsStringSync();
    expect(screen.contains('completeUnlink('), isTrue,
        reason: 'nothing else is mounted to finish it',);
    expect(screen.contains('UnlinkState.load()'), isTrue,
        reason: 'and nothing else is mounted to notice the far side either',);
    // Both drivers, one implementation.
    expect(shell.contains('completeUnlink('), isTrue);
  });
}
