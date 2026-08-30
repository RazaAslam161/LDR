import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/router.dart';

/// What the unlinking ritual lets through.
///
/// `unlinkAllows` is a pure function precisely so this can exist: the policy
/// it encodes is a safety argument, not a layout detail, and the alternative
/// is proving it by driving a GoRouter with a live session.
///
/// It takes only a path now. It used to take the row and the caller's id, to
/// decide one thing — that chat was open to the partner and closed to the
/// initiator. That asymmetry is gone (the partner was typing into a room the
/// other person could not enter), and with it the last per-role branch.
void main() {
  test('the ritual itself is always reachable', () {
    expect(unlinkAllows('/unlink'), isTrue);
  });

  test('the app is closed to both of them', () {
    // The takeover is the feature. If this list starts passing, the ritual has
    // quietly become a banner again.
    for (final path in [
      '/app',
      '/app/gallery',
      '/app/touch',
      '/app/games',
      '/app/closer/wish-jar',
      '/app/settings',
      '/app/settings/profile',
      '/app/timeline',
    ]) {
      expect(unlinkAllows(path), isFalse,
          reason: '$path was reachable during the ritual',);
    }
  });

  group('the exits are never gated on the ceremony', () {
    // The client half of assertion #4 in 20260829120000. Trapping somebody
    // inside a screen about leaving is the precise failure this feature
    // exists to stop being — and the account route is Play policy besides.
    for (final path in [
      '/app/settings/export',
      '/app/settings/account',
      '/rewrap',
      '/call',
    ]) {
      test('$path stays open', () {
        expect(unlinkAllows(path), isTrue);
      });
    }
  });

  test('chat is NOT reachable — it was a monologue, and it is gone', () {
    // "Talk to them" opened a chat the initiator was locked out of, so the
    // partner typed into a room nobody could enter. The note is the channel;
    // it renders on the initiator's screen beside Re-link. If this ever passes
    // again, that button has come back in the shape that did not work.
    expect(unlinkAllows('/unlink/chat'), isFalse);
  });

  test('an unknown route is refused, not allowed', () {
    // The default has to be closed. A route added next year that nobody
    // thought about during a breakup must land on the ritual, not leak.
    expect(unlinkAllows('/app/some-future-room'), isFalse);
    expect(unlinkAllows('/unlink/chat/attachments'), isFalse);
  });
}
