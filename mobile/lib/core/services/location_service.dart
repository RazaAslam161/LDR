import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Symmetric, opt-in, revocable location sharing.
///
/// Modes: 'off' (nothing shared), 'city' (only a "City, Country" label — NO
/// coordinates persisted), 'precise' (coords + a finer label). The user picks
/// per-account; either partner can turn it off any time. Foreground only.
class LocationService {
  LocationService._();

  static Future<LocationPermission> ensurePermission() async {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return p;
  }

  static bool blocked(LocationPermission p) =>
      p == LocationPermission.denied || p == LocationPermission.deniedForever;

  // ── Always-on (background) opt-in ──────────────────────────────────────────
  static const _alwaysKey = 'location_always_on';

  /// Whether this user opted into sharing with the app closed.
  static Future<bool> isAlwaysOn() async =>
      (await SharedPreferences.getInstance()).getBool(_alwaysKey) ?? false;

  static Future<void> setAlwaysOnPref({required bool value}) async =>
      (await SharedPreferences.getInstance()).setBool(_alwaysKey, value);

  /// "Allow all the time" — required to keep updating when the app is closed.
  /// Android 11+ won't grant it in the normal request flow; the caller sends the
  /// user to app settings (openAppSettings) to pick it, then we re-check here.
  static Future<bool> hasBackgroundPermission() async =>
      await Geolocator.checkPermission() == LocationPermission.always;

  /// Reads the device location (per [mode]) and pushes it to the presence row.
  /// Returns the human label, or null if it couldn't (off / denied / error).
  static Future<String?> shareOnce(String coupleId, String mode) async {
    if (mode == 'off') {
      await PresenceService.setLocation(coupleId, mode: 'off');
      return null;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final perm = await ensurePermission();
      if (blocked(perm)) return null;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy:
              mode == 'precise' ? LocationAccuracy.high : LocationAccuracy.low,
        ),
      );

      String? label;
      try {
        final marks =
            await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (marks.isNotEmpty) {
          final m = marks.first;
          final parts = mode == 'city'
              ? [m.locality, m.country]
              : [m.subLocality ?? m.locality, m.administrativeArea, m.country];
          label = parts.where((e) => e != null && e.isNotEmpty).join(', ');
        }
      } catch (_) {
        // geocoding can fail offline — fall through to a generic label
      }
      label = (label == null || label.isEmpty) ? 'Sharing location' : label;

      if (mode == 'city') {
        // City mode: send ONLY the label, never the coordinates.
        await PresenceService.setLocation(coupleId, mode: 'city', label: label);
      } else {
        await PresenceService.setLocation(coupleId,
            mode: 'precise',
            lat: pos.latitude,
            lon: pos.longitude,
            label: label);
      }
      return label;
    } catch (_) {
      return null;
    }
  }

  // ── Live (precise) streaming ───────────────────────────────────────────────
  static StreamSubscription<Position>? _liveSub;
  static double? _lastLabelLat;
  static double? _lastLabelLon;

  static bool get isLiveSharing => _liveSub != null;

  /// Reverse-geocode a coarse "Area, Region, Country" label (best-effort).
  static Future<String?> _label(double lat, double lon) async {
    try {
      final marks = await placemarkFromCoordinates(lat, lon);
      if (marks.isNotEmpty) {
        final m = marks.first;
        final label = [
          m.subLocality ?? m.locality,
          m.administrativeArea,
          m.country
        ].where((e) => e != null && e.isNotEmpty).join(', ');
        if (label.isNotEmpty) return label;
      }
    } catch (_) {
      // geocoding can fail offline / rate-limit — keep the previous label
    }
    return null;
  }

  /// Re-geocode the label only on the first fix or after a meaningful move
  /// (~700 m), so the dashboard text follows the live map without geocoding
  /// every 10 m tick.
  static Future<String?> _labelIfMoved(double lat, double lon) async {
    final moved = _lastLabelLat == null ||
        Geolocator.distanceBetween(_lastLabelLat!, _lastLabelLon!, lat, lon) >
            700;
    if (!moved) return null;
    final label = await _label(lat, lon);
    if (label != null) {
      _lastLabelLat = lat;
      _lastLabelLon = lon;
    }
    return label;
  }

  /// Streams the device position (foreground) and upserts each fix to presence.
  /// Returns false if location is off / permission denied. Symmetric + opt-in:
  /// the caller turns this on; either partner can stop it any time.
  static Future<bool> startLiveSharing(String coupleId) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      final perm = await ensurePermission();
      if (blocked(perm)) return false;

      _lastLabelLat = null;
      _lastLabelLon = null;

      // Push one fix immediately (with a fresh label) so the partner sees us.
      final first = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await PresenceService.setLiveLocation(coupleId,
          lat: first.latitude,
          lon: first.longitude,
          accuracy: first.accuracy,
          label: await _labelIfMoved(first.latitude, first.longitude));

      // Foreground-only streaming — NO persistent notification. Android requires
      // a sticky notification for a background-location foreground service, which
      // the couple didn't want, so we stream only while the app is alive.
      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );

      await _liveSub?.cancel();
      _liveSub =
          Geolocator.getPositionStream(locationSettings: settings).listen(
        (pos) async => PresenceService.setLiveLocation(coupleId,
            lat: pos.latitude,
            lon: pos.longitude,
            accuracy: pos.accuracy,
            label: await _labelIfMoved(pos.latitude, pos.longitude)),
        onError: (_) {},
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Stops streaming and clears the shared coords (no covert/stale tracking).
  static Future<void> stopLiveSharing(String coupleId) async {
    await _liveSub?.cancel();
    _liveSub = null;
    _lastLabelLat = null;
    _lastLabelLon = null;
    await PresenceService.clearLiveLocation(coupleId);
  }

  /// Stop the stream WITHOUT changing the sharing mode — used when the app
  /// backgrounds / leaves Home. NO-OP when always-on is enabled, so opted-in
  /// users keep streaming (via the foreground service) with the app closed.
  static Future<void> pauseStream() async {
    await _liveSub?.cancel();
    _liveSub = null;
  }
}
