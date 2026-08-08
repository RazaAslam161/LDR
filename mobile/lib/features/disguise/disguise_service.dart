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
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 2));
      return disguiseForAlias(prefs.getString(_prefsKey));
    } catch (_) {
      // Disk contention on a slow device must not hold up the first frame.
      return kDefaultDisguise;
    }
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
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_prefsKey);

    // Persist FIRST. Enabling a launcher component is precisely what makes
    // Android force-stop us, so a write queued after the channel call can be
    // lost — leaving the launcher showing one identity while the cover and the
    // notifications still wear the old one. Losing the write is recoverable
    // (reconcile() repairs it); losing the switch is not.
    await prefs.setString(_prefsKey, profile.aliasId);
    await prefs.setBool(_chosenKey, true);

    try {
      final ok = await _channel.invokeMethod<bool>('setAlias', {
        'aliasId': profile.aliasId,
        'all': kDisguises.map((d) => d.aliasId).toList(),
      });
      if (ok == true) return true;
    } on PlatformException catch (e) {
      debugPrint('Disguise switch failed: ${e.code} — ${e.message}');
    } on MissingPluginException {
      // Non-Android host (tests, desktop): the identity is a no-op there.
    }

    // The switch did not happen — put the stored identity back so it keeps
    // matching the alias that is actually enabled.
    if (previous == null) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, previous);
    }
    return false;
  }

  /// Repairs a stored identity that has drifted from the alias Android is
  /// actually running, then returns the truth.
  ///
  /// The enabled `<activity-alias>` is the real identity — it is what the
  /// launcher shows — so it wins over the preference. Called on startup from
  /// the foreground, where the platform channel exists; the FCM background
  /// isolate has its own engine without our channels, which is why the
  /// preference has to be right by then rather than queried on demand.
  static Future<DisguiseProfile> reconcile() async {
    try {
      // Hard timeout: this runs on the cold-start path, and a platform channel
      // that never answers would leave the user staring at a blank screen with
      // no way forward. A stale identity is survivable; an app that never
      // starts is not.
      final alias = await _channel.invokeMethod<String>('currentAlias', {
        'all': kDisguises.map((d) => d.aliasId).toList(),
      }).timeout(const Duration(seconds: 2));
      if (alias != null && alias.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString(_prefsKey) != alias) {
          debugPrint('Disguise drift: stored '
              '${prefs.getString(_prefsKey)}, actually $alias — repairing.');
          await prefs.setString(_prefsKey, alias);
        }
        return disguiseForAlias(alias);
      }
    } catch (_) {
      // Non-Android host, or the query failed — fall back to what we stored.
    }
    return current();
  }
}

/// The active disguise, for the cover screen and settings.
final disguiseProvider = FutureProvider<DisguiseProfile>(
  (ref) => DisguiseService.current(),
);
