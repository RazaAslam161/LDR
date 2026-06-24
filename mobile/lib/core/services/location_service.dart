import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/presence_service.dart';

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
        final marks = await placemarkFromCoordinates(
            pos.latitude, pos.longitude);
        if (marks.isNotEmpty) {
          final m = marks.first;
          final parts = mode == 'city'
              ? [m.locality, m.country]
              : [m.subLocality ?? m.locality, m.administrativeArea, m.country];
          label = parts
              .where((e) => e != null && e.isNotEmpty)
              .join(', ');
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

  static bool get isLiveSharing => _liveSub != null;

  /// Streams the device position (foreground) and upserts each fix to presence.
  /// Returns false if location is off / permission denied. Symmetric + opt-in:
  /// the caller turns this on; either partner can stop it any time.
  static Future<bool> startLiveSharing(String coupleId) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      final perm = await ensurePermission();
      if (blocked(perm)) return false;

      // Push one fix immediately so the partner sees us right away.
      final first = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await PresenceService.setLiveLocation(coupleId,
          lat: first.latitude, lon: first.longitude, accuracy: first.accuracy);

      await _liveSub?.cancel();
      _liveSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10, // metres — battery + privacy friendly
        ),
      ).listen(
        (pos) => PresenceService.setLiveLocation(coupleId,
            lat: pos.latitude, lon: pos.longitude, accuracy: pos.accuracy),
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
    await PresenceService.clearLiveLocation(coupleId);
  }

  /// Stop the stream WITHOUT changing the sharing mode — used when the app
  /// backgrounds (we resume on foreground). Battery + privacy.
  static Future<void> pauseStream() async {
    await _liveSub?.cancel();
    _liveSub = null;
  }
}
