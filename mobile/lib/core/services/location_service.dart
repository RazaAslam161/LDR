import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/bg_location.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_service.dart';
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

      // In-app GPS stream (fast, foreground). The persistent foreground service
      // (started below) keeps location flowing when backgrounded; Android requires
      // its sticky notification, which therefore shows ONLY while live-sharing is on.
      const settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );

      await _liveSub?.cancel();
      // LOCATION ONLY — this GPS stream must never call setOnline or any
      // app-activity method. setLiveLocation never stamps app_last_active_at,
      // so movement can't pollute the partner's online / last-seen.
      _liveSub =
          Geolocator.getPositionStream(locationSettings: settings).listen(
        (pos) async => PresenceService.setLiveLocation(coupleId,
            lat: pos.latitude,
            lon: pos.longitude,
            accuracy: pos.accuracy,
            label: await _labelIfMoved(pos.latitude, pos.longitude)),
        onError: (_) {},
      );

      // Persist the sharing mode so the foreground-service isolate can read it
      // and decide whether to keep writing coords while the app is backgrounded.
      final uid = SupabaseService.client.auth.currentUser?.id ?? '';
      if (uid.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('location_sharing_mode_$uid', 'precise');
      }

      // Also start the persistent background foreground service so location
      // continues when the in-app stream is paused on background.
      // Only 'precise' mode uses the service — city mode never starts it.
      await LocationForegroundService.start(coupleId: coupleId, uid: uid);

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

    // Stop the persistent background service — sharing is fully off.
    await LocationForegroundService.stop();

    // Clear the persisted mode so the service isolate doesn't write stale
    // coords if it gets woken by the OS later.
    final uid = SupabaseService.client.auth.currentUser?.id ?? '';
    if (uid.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('location_sharing_mode_$uid', 'off');
    }
  }

  /// Turn OFF live streaming but KEEP the partner's view of your last position.
  ///
  /// Stops the in-app stream + the foreground service (its notification
  /// disappears) and the WorkManager fallback, and clears the local "live"
  /// intent so nothing auto-resumes. Unlike [stopLiveSharing] it does NOT wipe
  /// the shared coords or set mode 'off': it pushes ONE final 'precise' fix so
  /// the partner sees a static "last known" pin (with a growing "Xm ago"),
  /// never "isn't sharing location".
  static Future<void> stopLiveSharingKeepLast(String coupleId) async {
    await _liveSub?.cancel();
    _liveSub = null;
    _lastLabelLat = null;
    _lastLabelLon = null;

    // Remove the persistent notification + the periodic background updates.
    await LocationForegroundService.stop();
    await BgLocationService.disable();

    // Clear the persisted live intent so resume/init won't restart streaming
    // and the service isolate won't write coords if the OS wakes it.
    final uid = SupabaseService.client.auth.currentUser?.id ?? '';
    if (uid.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('location_sharing_mode_$uid', 'off');
    }

    // Push ONE final fix (one-shot, not streaming) so the partner keeps seeing
    // the last position as a static pin. Mode stays 'precise' — NOT 'off'.
    try {
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await PresenceService.setLocation(
        coupleId,
        mode: 'precise',
        lat: pos.latitude,
        lon: pos.longitude,
      );
    } catch (_) {
      // Couldn't get a fix — leave the last live coords in place (still shown).
    }
  }

  /// Whether the user's persisted choice is live ('precise') sharing. Local +
  /// offline-safe — the source of truth for "should we be live-sharing?". Kept
  /// in sync by start/stopLiveSharing (including the Home location toggle).
  static Future<bool> isLiveModeOn() async {
    final uid = SupabaseService.client.auth.currentUser?.id ?? '';
    if (uid.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('location_sharing_mode_$uid') == 'precise';
  }

  /// Make sure live sharing is fully OFF: stops the in-app stream and the
  /// persistent foreground service (removing its notification) and clears the
  /// persisted intent. Does NOT write presence — used to reconcile stale device
  /// state when the user isn't live-sharing (e.g. left over from an old build).
  static Future<void> ensureLiveOff() async {
    await _liveSub?.cancel();
    _liveSub = null;
    await LocationForegroundService.stop();
    final uid = SupabaseService.client.auth.currentUser?.id ?? '';
    if (uid.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('location_sharing_mode_$uid', 'off');
    }
  }

  /// Stop the in-app stream WITHOUT changing the sharing mode — used when the
  /// app backgrounds / leaves Home.
  //
  // Only the in-app stream is paused. The foreground service keeps running in
  // the background, so opted-in users keep streaming live coords with the app
  // closed. NO-OP for the service here by design.
  static Future<void> pauseStream() async {
    await _liveSub?.cancel();
    _liveSub = null;
  }
}
