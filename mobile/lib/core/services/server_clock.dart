import 'package:flutter/foundation.dart';

/// The server's clock, as best this device can know it.
///
/// Freshness ("is my partner online right now") is a comparison between a
/// timestamp and *now*. Presence used to take both from devices: the partner's
/// phone stamped app_last_active_at, this phone supplied DateTime.now(). Two
/// wrong clocks, one 45-second window, and the error is directional — a
/// partner whose clock runs slow is permanently offline to you, while you look
/// perfectly online to them.
///
/// The write half is fixed server-side (a BEFORE trigger stamps now()). This is
/// the read half: instead of trusting the local clock, learn how far it is from
/// the server's and correct for it. The offset comes free — every presence
/// write already returns the row the trigger just stamped, so [observe] is fed
/// by the 30-second heartbeat with no extra round trip.
///
/// Until the first observation this falls back to the device clock, which is no
/// worse than the old behaviour.
class ServerClock {
  ServerClock._();

  /// serverNow - deviceNow at the moment of the last observation.
  static Duration _offset = Duration.zero;
  static bool _known = false;

  static bool get isKnown => _known;
  static Duration get offset => _offset;

  /// Feed a timestamp that the SERVER generated, taken from a response.
  ///
  /// [sentAt] must be the device time captured immediately before the request
  /// so the round trip can be discounted; the true server instant lies
  /// somewhere inside the round trip, and its midpoint is the best estimate
  /// (this is what NTP does, minus the statistics).
  static void observe(DateTime serverTime, {required DateTime sentAt}) {
    final now = DateTime.now().toUtc();
    final roundTrip = now.difference(sentAt);
    // A pathological round trip makes the midpoint meaningless; a stale sample
    // is worse than the previous good one.
    if (roundTrip.isNegative || roundTrip > const Duration(seconds: 10)) return;
    final deviceMid = sentAt.add(roundTrip ~/ 2);
    final next = serverTime.toUtc().difference(deviceMid);

    if (_known && (next - _offset).abs() < const Duration(seconds: 2)) return;
    _offset = next;
    _known = true;
    if (next.abs() > const Duration(seconds: 30)) {
      // Worth knowing: this device's clock is wrong enough that everything
      // time-based would have been broken before this correction existed.
      debugPrint('[clock] device is ${next.inSeconds}s off server time');
    }
  }

  /// Server-relative now. Use this for every freshness comparison.
  static DateTime now() => DateTime.now().toUtc().add(_offset);

  @visibleForTesting
  static void reset() {
    _offset = Duration.zero;
    _known = false;
  }

  @visibleForTesting
  static void setOffsetForTest(Duration d) {
    _offset = d;
    _known = true;
  }
}
