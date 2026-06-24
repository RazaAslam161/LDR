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
}
