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

  /// Whether this build carries the disguise at all.
  ///
  /// The play channel declares no `<activity-alias>` and installs under the
  /// app's own name and icon, so nothing there is being hidden: a cover screen
  /// would front an honest app with a fake news reader, and the picker's nine
  /// invented identities are the Deceptive Behavior finding that channel exists
  /// to avoid.
  ///
  /// True until [loadEnabled] says otherwise. The wrong answer that way costs a
  /// build that has never shipped a moment of cover; the wrong answer the other
  /// way strips the disguise off a sideloaded phone mid-session.
  static bool enabled = true;

  /// Whether this build installs as itself.
  ///
  /// The Play channel declares `.AliasMiles` alongside the nine covers, all of
  /// them disabled, and starts on Miles — so a cover is something the owner
  /// switches ON from Settings, never the state they were handed. The sideload
  /// channel has no such component and starts on News, which is the point of
  /// that channel.
  ///
  /// Two things follow: the plain identity has to be in the `all` list so
  /// switching away from it disables it, and nothing may prompt for a cover
  /// unasked — a store build that opens a disguise picker on first run is
  /// offering something the user did not come for.
  static bool plainDefault = false;

  /// Every alias this build declares, plain identity FIRST.
  ///
  /// Order is load-bearing on a fresh install. Nothing has been toggled yet, so
  /// every alias reports COMPONENT_ENABLED_STATE_DEFAULT and the native side
  /// takes the first match — which must be the identity the manifest actually
  /// ships enabled, or the app opens wearing a cover nobody chose. Both
  /// manifests enable the plain alias, so it leads.
  static List<String> get _allAliases => [
        kPlainProfile.aliasId,
        ...kDisguises.map((d) => d.aliasId),
      ];

  /// What the picker may offer. The plain identity leads, because on a build
  /// that starts there it is also the way back.
  static List<DisguiseProfile> get choices =>
      [if (plainDefault) kPlainProfile, ...kDisguises];

  static DisguiseProfile get _installedIdentity =>
      plainDefault ? kPlainProfile : kDefaultDisguise;

  /// Reads [enabled] from the native BuildConfig, once. Must complete before
  /// runApp — see main().
  static Future<void> loadEnabled() async {
    try {
      // Same hard timeout as reconcile(), for the same reason: this is on the
      // cold-start path and nothing may block the first frame on it.
      enabled = await _channel
              .invokeMethod<bool>('isEnabled')
              .timeout(const Duration(seconds: 2)) ??
          true;
      plainDefault = await _channel
              .invokeMethod<bool>('isPlainDefault')
              .timeout(const Duration(seconds: 2)) ??
          false;
    } catch (_) {
      // Non-Android host, or the query failed — keep the disguise.
    }
  }

  /// The active profile. Reads the persisted choice rather than the platform,
  /// because Android cannot tell us which alias is enabled without a query per
  /// component, and the two are kept in lockstep by [apply].
  static Future<DisguiseProfile> current() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 2));
      final stored = prefs.getString(_prefsKey);
      // Nothing stored means nothing was ever chosen, and what the launcher is
      // showing then is whichever alias the manifest enabled — News on
      // sideload, Miles on Play. Answering kDefaultDisguise for both would tell
      // a Play install it is wearing a cover it is not.
      if (stored == null) return _installedIdentity;
      return disguiseForAlias(stored);
    } catch (_) {
      // Disk contention on a slow device must not hold up the first frame.
      return _installedIdentity;
    }
  }

  /// Answers true unasked when there is no disguise to offer, so AppShell's
  /// one-time onboarding prompt never pushes a picker with nothing in it.
  static Future<bool> hasChosen() async =>
      !enabled ||
      ((await SharedPreferences.getInstance()).getBool(_chosenKey) ?? false);

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
        'all': _allAliases,
      });
      if (ok ?? false) return true;
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
        'all': _allAliases,
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
