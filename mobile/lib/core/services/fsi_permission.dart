import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Full-screen-intent permission (Android 14 / API 34+).
///
/// On API < 34 it's implicitly granted. From 34, the user must allow it in
/// system settings — Tethered does NOT auto-qualify (it's not a calling/alarm
/// app), so we *request* it and always degrade gracefully to a heads-up
/// notification when it's denied.
class FsiPermission {
  FsiPermission._();

  static const _channel = MethodChannel('miles/fsi');
  static const _askedKey = 'fsi_prompt_shown';
  static const _cacheKey = 'fsi_can_use'; // read by the background isolate

  /// Whether a full-screen intent can currently wake the screen.
  static Future<bool> canUse() async {
    try {
      return await _channel.invokeMethod<bool>('canUseFullScreenIntent') ?? false;
    } catch (_) {
      // Channel only exists on Android with our MainActivity; assume true so
      // non-Android / older platforms keep their legacy behaviour.
      return true;
    }
  }

  /// Opens the system page where the user toggles full-screen alerts on.
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('openSettings');
    } catch (_) {}
  }

  /// Mirrors the live permission into SharedPreferences so the FCM background
  /// isolate (which has no Activity / platform channel) can read it.
  static Future<bool> refreshCache() async {
    final can = await canUse();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cacheKey, can);
    return can;
  }

  /// One-time, dismissible prompt. Shows only when FSI is actually unavailable
  /// and we haven't asked before. Re-accessible any time from Settings.
  static Future<void> promptIfNeeded(
    BuildContext context,
    String partnerName,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedKey) ?? false) return;
    if (await canUse()) return; // already granted (or < API 34)
    await prefs.setBool(_askedKey, true);
    if (!context.mounted) return;

    final allow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Let them wake your screen 💕'),
        content: Text(
          'To let $partnerName light up your phone when they reach for you '
          '(even when it\'s locked), allow full-screen alerts. Without it you\'ll '
          'still get a notification — just not the wake-the-screen kind.',
          style: const TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: MilesColors.blush),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (allow ?? false) {
      await openSettings();
      // Re-cache shortly after, once they return from settings.
      await refreshCache();
    }
  }
}
