import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Real IANA timezone conversion for Sky Bridge + Countdown.
///
/// The app stores each partner's zone as an IANA name (e.g. `Asia/Karachi`).
/// Dart's core `DateTime` can only do the *device's* local zone, which is why
/// Sky Bridge used to show the wrong sky and a 0h offset. This wraps the
/// `timezone` package so we can ask "what's the wall-clock time right now in
/// <their zone>?" regardless of where this phone is.
class TzHelper {
  TzHelper._();

  static bool _ready = false;

  /// Loads the IANA database once. Cheap to call repeatedly.
  static void ensureInit() {
    if (_ready) return;
    tzdata.initializeTimeZones();
    _ready = true;
  }

  /// Wall-clock time *right now* in [ianaName]. Falls back to UTC if unknown.
  static tz.TZDateTime nowIn(String ianaName) =>
      tz.TZDateTime.now(_location(ianaName));

  /// Convert a UTC [instant] into wall-clock time in [ianaName].
  static tz.TZDateTime inZone(DateTime instant, String ianaName) =>
      tz.TZDateTime.from(instant.toUtc(), _location(ianaName));

  /// Whole-hour offset of [b] relative to [a] right now (DST-aware).
  /// Positive = b is ahead of a.
  static int offsetHours(String a, String b) {
    final minutes =
        nowIn(b).timeZoneOffset.inMinutes - nowIn(a).timeZoneOffset.inMinutes;
    return (minutes / 60).round();
  }

  static tz.Location _location(String ianaName) {
    ensureInit();
    try {
      return tz.getLocation(ianaName);
    } catch (_) {
      return tz.UTC;
    }
  }
}
