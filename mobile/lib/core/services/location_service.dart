import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What stands between the saved sharing mode and an actual position fix.
///
/// The app used to collapse all of these into `return null`, so "you never
/// allowed location", "you revoked it in App info" and "location is switched
/// off device-wide" were indistinguishable from "sent fine" — to the code and
/// to the user. Each one is fixed on a different screen, so each one has to be
/// nameable.
enum LocationBlock {
  /// Permission held and the device's location service is on.
  none,

  /// Permission held, but location is off device-wide. Nothing the app can
  /// prompt for — only the system location page turns it back on.
  serviceDisabled,

  /// Refused, but still re-askable.
  denied,

  /// Refused permanently, or blocked by policy. Only App info can undo it.
  deniedForever,
}

/// Symmetric, opt-in, revocable location sharing — FOREGROUND ONLY.
///
/// Modes: 'off' (nothing shared), 'city' (only a "City, Country" label — NO
/// coordinates), 'precise' (coords + a finer label). The user picks per-account
/// in Settings; either partner can turn it off any time. While the app is open
/// and the mode isn't 'off', Home pushes the current position every ~15s. There
/// is no live toggle, no foreground service, no background location.
///
/// The mode is an intention stored on the server; the OS permission is a fact
/// stored on the handset, and it is per-install, not per-account. Neither one
/// implies the other, so everything here reports which of the two is missing
/// rather than quietly doing nothing.
class LocationService {
  LocationService._();

  /// Never prompts — safe on every tick and every build.
  static Future<LocationBlock> check() async =>
      _resolveBlock(await Geolocator.checkPermission());

  /// Prompts if the OS will still show the sheet, then reports what is left.
  static Future<LocationBlock> request() async {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return _resolveBlock(p);
  }

  /// Permission is checked before the service, because a granted permission
  /// with the device's location switched off is a different repair on a
  /// different system page.
  static Future<LocationBlock> _resolveBlock(LocationPermission p) async {
    switch (p) {
      case LocationPermission.deniedForever:
        return LocationBlock.deniedForever;
      case LocationPermission.denied:
      case LocationPermission.unableToDetermine:
        return LocationBlock.denied;
      case LocationPermission.whileInUse:
      case LocationPermission.always:
        return await Geolocator.isLocationServiceEnabled()
            ? LocationBlock.none
            : LocationBlock.serviceDisabled;
    }
  }

  /// Reads the device location (per [mode]) and pushes it to the presence row.
  /// Returns the human label, or null if it couldn't (off / blocked / error).
  static Future<String?> shareOnce(String coupleId, String mode) async {
    if (mode == 'off') {
      await PresenceService.setLocation(coupleId, mode: 'off');
      return null;
    }
    try {
      if (await check() != LocationBlock.none) return null;

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
  /// one tick. Drives Home's 15s foreground update loop.
  ///
  /// Returns what stopped the push so Home can put it on screen. A mode of
  /// 'off' returns [LocationBlock.none]: nothing is wrong, there is simply
  /// nothing to send.
  static Future<LocationBlock> shareCurrent(String coupleId) async {
    final mine = await PresenceService.fetchMine(coupleId);
    final mode = mine?.locationSharingMode ?? 'off';
    if (mode == 'off') return LocationBlock.none;
    final block = await check();
    if (block != LocationBlock.none) return block;
    await shareOnce(coupleId, mode);
    return LocationBlock.none;
  }

  /// Turn sharing on the first time the OS permission is actually granted.
  ///
  /// The app asked for location permission at startup and then defaulted the
  /// sharing mode to 'off', so granting it did nothing visible: the partner's
  /// Home stayed empty until the user found the toggle in Settings and set it
  /// themselves. Two separate switches for one intention, and only one of them
  /// was in front of the user.
  ///
  /// 'city' rather than 'precise' on purpose — the coarse option is the polite
  /// default for something enabled on the user's behalf, and Settings still
  /// offers precise, or off.
  ///
  /// Runs at most once per ACCOUNT on this handset: after that the stored mode
  /// is that user's own choice and must not be overridden, including their
  /// choice of 'off'. The flag used to be device-wide, so the second person to
  /// sign in on a phone was silently skipped and started with sharing off and
  /// no explanation.
  static Future<void> adoptPermissionAsDefault(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final key = 'location_mode_defaulted_$uid';
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(key) ?? false) return;

    // Deliberately not `check()`: a permission that is held while the device's
    // location happens to be switched off is still a granted permission, and
    // the intention it expresses outlives the toggle.
    final p = await Geolocator.checkPermission();
    if (p != LocationPermission.whileInUse && p != LocationPermission.always) {
      return;
    }
    await prefs.setBool(key, true);

    final mine = await PresenceService.fetchMine(coupleId);
    if ((mine?.locationSharingMode ?? 'off') != 'off') return; // already chosen
    await PresenceService.setSharingMode(coupleId, 'city');
    await shareOnce(coupleId, 'city');
  }

  /// The first-run ask, once per account on this handset.
  ///
  /// A cold system dialog gets denied. This used to be fired from the
  /// permission blast in the first frame of main.dart — before sign-up, before
  /// pairing, before the user had seen a single screen — which asked a stranger
  /// for their location and then treated the inevitable refusal as permanent.
  /// The rationale below runs first, and it names the person it is for.
  static Future<void> onboard(
    BuildContext context,
    String coupleId,
    String partnerName,
  ) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final key = 'location_onboarded_$uid';
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(key) ?? false) return;

    if (await check() == LocationBlock.none) {
      // Granted already — a re-install, or the second account on a phone whose
      // first account allowed it. Nothing to explain, but the sharing mode
      // still has to follow.
      await prefs.setBool(key, true);
      await adoptPermissionAsDefault(coupleId);
      return;
    }

    if (!context.mounted) return;
    final wants = await _confirm(
      context,
      'Let $partnerName see where you are 📍',
      "Miles can show $partnerName the city you're in — or your exact spot, if "
          'you choose that — while the app is open. Never in the background, '
          'never to anyone else, and you can switch it off in Settings at any '
          'time.',
      'Choose',
    );
    // Asked, whatever the answer: the first run is not repeated. Settings and
    // the notice on Home are the ways back in.
    await prefs.setBool(key, true);
    if (!wants || !context.mounted) return;

    await resolve(context);
    await adoptPermissionAsDefault(coupleId);
  }

  /// Ask for the permission and, if something is still in the way, say what it
  /// is and open the one system page that can fix it.
  ///
  /// A plain [LocationBlock.denied] returns quietly: the user has just said no
  /// on the OS sheet, and following that with a dialog is nagging. The notice
  /// on Home is where they pick it up again.
  static Future<LocationBlock> resolve(BuildContext context) async {
    final block = await request();
    if (block == LocationBlock.none || block == LocationBlock.denied) {
      return block;
    }
    if (!context.mounted) return block;

    final go = block == LocationBlock.serviceDisabled
        ? await _confirm(
            context,
            'Location is switched off',
            "Your phone's location is off, so there's nothing for Miles to "
                'share. Turn it on in your phone settings and come back.',
            'Open settings',
          )
        : await _confirm(
            context,
            'Miles cannot read your location',
            'Location is blocked for this app, so your partner sees nothing. '
                "You can allow it under Permissions in this app's settings.",
            'Open settings',
          );
    if (!go) return block;

    if (block == LocationBlock.serviceDisabled) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
    return check();
  }

  /// One sentence of why, then the choice. Returns false on a dismissal.
  static Future<bool> _confirm(
    BuildContext context,
    String title,
    String body,
    String action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: Text(title),
        content: Text(
          body,
          style: const TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MilesColors.blush),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}
