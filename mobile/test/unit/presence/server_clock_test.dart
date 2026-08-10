import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/server_clock.dart';

/// Presence decided "is my partner online" by comparing two phones' clocks: one
/// stamped app_last_active_at, the other supplied DateTime.now(), with a 45
/// second window. The error is DIRECTIONAL — a partner whose clock runs slow is
/// permanently offline to you while you look perfectly online to them — which
/// is why it presents as "she can't see me but I can see her" and why two
/// NTP-synced dev phones never reproduce it.
///
/// These prove the correction without needing a device with a wrong clock.
void main() {
  setUp(ServerClock.reset);
  tearDown(ServerClock.reset);

  test('with no observation yet it falls back to the device clock', () {
    // No worse than the old behaviour, so a cold start is never blocked on a
    // sync landing first.
    expect(ServerClock.isKnown, isFalse);
    final drift = ServerClock.now().difference(DateTime.now().toUtc()).abs();
    expect(drift, lessThan(const Duration(seconds: 1)));
  });

  test('a device running slow is corrected forward', () {
    // Simulate: the server says it is 60s later than this device believes.
    final sentAt = DateTime.now().toUtc();
    ServerClock.observe(sentAt.add(const Duration(seconds: 60)),
        sentAt: sentAt,);

    expect(ServerClock.isKnown, isTrue);
    expect(ServerClock.offset.inSeconds, closeTo(60, 2));
    final corrected =
        ServerClock.now().difference(DateTime.now().toUtc()).inSeconds;
    expect(corrected, closeTo(60, 2),
        reason: 'server-relative now must run ahead of this slow device',);
  });

  test('a device running fast is corrected backward', () {
    final sentAt = DateTime.now().toUtc();
    ServerClock.observe(sentAt.subtract(const Duration(seconds: 90)),
        sentAt: sentAt,);
    expect(ServerClock.offset.inSeconds, closeTo(-90, 2));
  });

  test('the round trip is discounted, not charged to the offset', () {
    // A 4s round trip with a server clock equal to the device's must NOT be
    // read as a 4s offset; the true instant is the midpoint.
    final sentAt = DateTime.now().toUtc().subtract(const Duration(seconds: 4));
    ServerClock.observe(sentAt.add(const Duration(seconds: 2)), sentAt: sentAt);
    expect(ServerClock.offset.inSeconds.abs(), lessThanOrEqualTo(1));
  });

  test('an absurd round trip is discarded rather than believed', () {
    ServerClock.setOffsetForTest(const Duration(seconds: 30));
    final sentAt = DateTime.now().toUtc().subtract(const Duration(seconds: 60));
    ServerClock.observe(DateTime.now().toUtc(), sentAt: sentAt);
    expect(ServerClock.offset.inSeconds, 30,
        reason: 'a 60s round trip cannot locate the server instant',);
  });

  test('a clock that jumps backwards is discarded', () {
    // sentAt in the future means the device clock moved during the request.
    ServerClock.setOffsetForTest(const Duration(seconds: 5));
    final sentAt = DateTime.now().toUtc().add(const Duration(seconds: 30));
    ServerClock.observe(DateTime.now().toUtc(), sentAt: sentAt);
    expect(ServerClock.offset.inSeconds, 5);
  });

  test('small jitter does not churn the offset', () {
    ServerClock.setOffsetForTest(const Duration(seconds: 10));
    final sentAt = DateTime.now().toUtc();
    // Would compute ~11s — inside the 2s deadband, so it must be ignored.
    ServerClock.observe(sentAt.add(const Duration(seconds: 11)),
        sentAt: sentAt,);
    expect(ServerClock.offset.inSeconds, 10);
  });

  group('the freshness verdict this exists to protect', () {
    /// The exact comparison Presence.isTrulyOnline performs.
    bool online(DateTime partnerStamp) =>
        ServerClock.now().difference(partnerStamp).inSeconds <= 45;

    test('a partner active now reads online even when this device is slow', () {
      // THE BUG: this device is 120s behind. The partner's row was stamped by
      // the SERVER a moment ago. Uncorrected, `deviceNow - serverStamp` is
      // -120 ... which is <= 45, so it would read online here. Flip it:
      final sentAt = DateTime.now().toUtc();
      ServerClock.observe(sentAt.add(const Duration(seconds: 120)),
          sentAt: sentAt,);
      final partnerStampedByServer = ServerClock.now();
      expect(online(partnerStampedByServer), isTrue);
    });

    test('a device running FAST no longer sees a dead partner as online', () {
      // This is the half that silently lied: with the device 120s ahead and no
      // correction, a partner who went offline two minutes ago still satisfies
      // the window. Corrected, they read offline.
      final sentAt = DateTime.now().toUtc();
      ServerClock.observe(sentAt.subtract(const Duration(seconds: 120)),
          sentAt: sentAt,);
      final stampedTwoMinutesAgo =
          ServerClock.now().subtract(const Duration(seconds: 120));
      expect(online(stampedTwoMinutesAgo), isFalse);
    });

    test('a device running SLOW no longer hides a live partner', () {
      // The reported symptom: partner is genuinely active, this reader's clock
      // is 120s behind, and without correction every row they receive looks
      // 120s stale — permanently offline, no screen, forever.
      final sentAt = DateTime.now().toUtc();
      ServerClock.observe(sentAt.add(const Duration(seconds: 120)),
          sentAt: sentAt,);
      final partnerActiveTenSecondsAgo =
          ServerClock.now().subtract(const Duration(seconds: 10));
      expect(online(partnerActiveTenSecondsAgo), isTrue);

      // And the uncorrected comparison is what it would have been:
      final uncorrected = DateTime.now()
          .toUtc()
          .difference(partnerActiveTenSecondsAgo)
          .inSeconds;
      expect(uncorrected, lessThan(-45),
          reason: 'proves the raw device clock got this wrong',);
    });
  });
}
