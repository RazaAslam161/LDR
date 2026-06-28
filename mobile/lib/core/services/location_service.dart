import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/presence_service.dart';

/// Symmetric, opt-in, revocable location sharing — FOREGROUND ONLY.
///
/// Modes: 'off' (nothing shared), 'city' (only a "City, Country" label — NO
/// coordinates), 'precise' (coords + a finer label). The user picks per-account
/// in Settings; either partner can turn it off any time. While the app is open
/// and the mode isn't 'off', Home pushes the current position every ~15s. There
/// is no live toggle, no foreground service, no background location.
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
        await PresenceService.setLocation(
          coupleId,
          mode: 'precise',
          lat: pos.latitude,
          lon: pos.longitude,
          accuracy: pos.accuracy,
          label: label,
        );
      }
      return label;
    } catch (_) {
      return null;
    }
  }

  /// Push the user's CURRENT position honouring their saved mode, which is read
  /// fresh each call — so turning sharing off in Settings stops sharing within
  /// one tick (and 'off' simply writes no coordinates). Drives Home's 15s
  /// foreground update loop.
  static Future<void> shareCurrent(String coupleId) async {
    final mine = await PresenceService.fetchMine(coupleId);
    await shareOnce(coupleId, mine?.locationSharingMode ?? 'off');
  }
}
