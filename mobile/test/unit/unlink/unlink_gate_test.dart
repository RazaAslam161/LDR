import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// What the unlinking ritual lets through.
///
/// `unlinkAllows` is a pure function precisely so this can exist: the policy
/// it encodes is a safety argument, not a layout detail, and the alternative
/// is proving it by driving a GoRouter with a live session.
UnlinkRow _row({required String initiator}) => UnlinkRow(
      coupleId: 'c1',
      initiatedBy: initiator,
      state: 'cooling',
      startedAt: DateTime.utc(2026, 8, 30, 12),
      coolingEndsAt: DateTime.utc(2026, 8, 31, 12),
      lastLookEndsAt: null,
      acceptedAt: null,
      relinkOpensAt: DateTime.utc(2026, 8, 30, 12, 15),
      partnerGateOpensAt: DateTime.utc(2026, 8, 30, 12, 15),
      noteCipherBytea: null,
      noteNonceBytea: null,
      noteAuthor: null,
      noteUpdatedAt: null,
    );

void main() {
  const me = 'u-me';
  const them = 'u-them';
  final asInitiator = _row(initiator: me);
  final asPartner = _row(initiator: them);

  test('the ritual itself is always reachable, by both of them', () {
    expect(unlinkAllows(asInitiator, me, '/unlink'), isTrue);
    expect(unlinkAllows(asPartner, me, '/unlink'), isTrue);
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
      expect(unlinkAllows(asInitiator, me, path), isFalse,
          reason: 'the initiator reached $path during the ritual',);
      expect(unlinkAllows(asPartner, me, path), isFalse,
          reason: 'the partner reached $path during the ritual',);
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
      test('$path stays open to both', () {
        expect(unlinkAllows(asInitiator, me, path), isTrue);
        expect(unlinkAllows(asPartner, me, path), isTrue);
      });
    }
  });

  group('chat', () {
    test('is open to the partner, who did not choose this', () {
      expect(unlinkAllows(asPartner, me, '/unlink/chat'), isTrue);
    });

    test('is closed to the initiator, who did', () {
      // Not an oversight and not a punishment: the room they closed is closed
      // to them too, and Re-link is the way back into it. A ritual with no
      // cost is a settings toggle.
      expect(unlinkAllows(asInitiator, me, '/unlink/chat'), isFalse);
    });

    test('is decided by the ROW, not by who is holding the phone', () {
      // Same person, same path, opposite answers — because the row says who
      // started it. A gate that read the local uid alone would hand chat to
      // whoever happened to be signed in.
      expect(unlinkAllows(asPartner, them, '/unlink/chat'), isFalse);
      expect(unlinkAllows(asInitiator, them, '/unlink/chat'), isTrue);
    });
  });

  test('an unknown route is refused, not allowed', () {
    // The default has to be closed. A route added next year that nobody
    // thought about during a breakup must land on the ritual, not leak.
    expect(unlinkAllows(asPartner, me, '/app/some-future-room'), isFalse);
    expect(unlinkAllows(asPartner, me, '/unlink/chat/attachments'), isFalse);
  });
}
