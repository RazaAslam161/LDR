import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Switches what the app looks like in the launcher.
///
/// Android has no runtime API for "change my icon". The only supported way is to
/// declare one `<activity-alias>` per identity in the manifest and enable
/// exactly one of them with `PackageManager.setComponentEnabledSetting`. That is
/// what the `miles/disguise` channel does.
///
/// Two things this must never get wrong:
///  * **The app must never end up with zero enabled aliases** — it would vanish
///    from the launcher with no way back in. The native side enables the new
///    alias BEFORE disabling the others, and refuses an unknown id outright.
///  * **The launcher may drop the app for a moment.** Switching a component the
///    running task was launched from can have Android kill the process, and some
///    launchers cache the old icon until they refresh. The picker warns about
///    this; it is a platform behaviour, not something we can fix.
class DisguiseService {
  DisguiseService._();

  static const _channel = MethodChannel('miles/disguise');
  static const _prefsKey = 'disguise_alias_id';

  /// Whether the user has been offered the choice yet. Kept separate from the
  /// chosen id so that "picked News deliberately" is distinguishable from
  /// "never asked".
  static const _chosenKey = 'disguise_chosen';

  /// The active profile. Reads the persisted choice rather than the platform,
  /// because Android cannot tell us which alias is enabled without a query per
  /// component, and the two are kept in lockstep by [apply].
  static Future<DisguiseProfile> current() async {
    final prefs = await SharedPreferences.getInstance();
    return disguiseForAlias(prefs.getString(_prefsKey));
  }

  static Future<bool> hasChosen() async =>
      (await SharedPreferences.getInstance()).getBool(_chosenKey) ?? false;

  /// Marks the picker as answered without changing the identity — for the user
  /// who taps "Keep it as it is".
  static Future<void> markChosen() async =>
      (await SharedPreferences.getInstance()).setBool(_chosenKey, true);

  /// Switches the launcher identity to [profile].
  ///
  /// Returns true when the platform confirmed the swap. On failure the previous
  /// identity is left intact and nothing is persisted, so a half-applied state
  /// is not possible.
  static Future<bool> apply(DisguiseProfile profile) async {
    try {
      final ok = await _channel.invokeMethod<bool>('setAlias', {
        'aliasId': profile.aliasId,
        'all': kDisguises.map((d) => d.aliasId).toList(),
      });
      if (ok != true) return false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, profile.aliasId);
      await prefs.setBool(_chosenKey, true);
      return true;
    } on PlatformException catch (e) {
      debugPrint('Disguise switch failed: ${e.code} — ${e.message}');
      return false;
    } on MissingPluginException {
      // Non-Android host (tests, desktop): the identity is a no-op there.
      return false;
    }
  }
}

/// The active disguise, for the cover screen and settings.
final disguiseProvider = FutureProvider<DisguiseProfile>(
  (ref) => DisguiseService.current(),
);
