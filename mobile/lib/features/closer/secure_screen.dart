import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/diag/diag.dart';

/// Sets/clears Android's `FLAG_SECURE` on the current activity window.
///
/// `FLAG_SECURE` prevents the surface from appearing in screenshots, screen
/// recordings, and the recent-apps preview — used inside Private Vault photo
/// views and Memory Threads per the intimacy spec.
///
/// Behaviour:
/// - On Android this calls the `miles/secure_screen` MethodChannel;
///   MainActivity.kt sets/clears WindowManager.LayoutParams.FLAG_SECURE on the
///   activity window and answers `isSecure`.
/// - There is no iOS equivalent, so there the channel has no host and the call
///   is a no-op.
/// - A platform failure is REPORTED (ErrorReporter, kind 'secure-screen'), and
///   [active] is only set once the platform confirmed the flag — a banner that
///   promised a protection the window never got was the defect.
class SecureScreen {
  SecureScreen._();

  static const _channel = MethodChannel('miles/secure_screen');

  /// Whether FLAG_SECURE is currently applied — true while ANY holder wants it.
  ///
  /// Read by the screen-share banner. Android blanks a FLAG_SECURE window in
  /// MediaProjection output, so walking into the Vault or Memory Threads while
  /// sharing sends the partner a black rectangle. That is the correct privacy
  /// behaviour and is not changed here — but it used to happen in total
  /// silence, with neither person able to tell it from a broken share.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// How many screens currently want the flag.
  ///
  /// REFCOUNTED, and that is the whole point. These holders nest: the memory
  /// photo viewer is pushed on top of the unlocked timeline, and the vault
  /// viewer on top of the vault. Under the old last-call-wins rule the inner
  /// screen's dispose cleared the flag outright, handing the still-visible
  /// intimate screen underneath back to screenshots, screen recording and the
  /// recents preview — and flipping [active] false, so the screen-share banner
  /// promised a protection that was gone.
  static int _holders = 0;

  @visibleForTesting
  static int get holders => _holders;

  /// Take a reference. The flag goes on when the first holder arrives.
  static Future<void> acquire() async {
    _holders++;
    if (_holders > 1) return;
    // A report, not a wish: the flag is on only when the platform said so.
    if (await _invoke('setSecure', {'enable': true})) active.value = true;
  }

  /// Drop a reference. The flag comes off only when the last holder leaves.
  static Future<void> release() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders > 0) return;
    // Cleared first: whatever the platform answers, nothing may claim the
    // flag after the last holder left.
    active.value = false;
    await _invoke('setSecure', {'enable': false});
  }

  @visibleForTesting
  static void resetForTest() {
    _holders = 0;
    active.value = false;
  }

  /// True when the platform call completed. This app ships Android only, so a
  /// missing host is a defect, not a platform; both failures are reported
  /// (ErrorReporter dedupes by kind+type, so a broken channel costs one row).
  static Future<bool> _invoke(String method,
      [Map<String, dynamic>? args,]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      return true;
    } on MissingPluginException catch (e, st) {
      ErrorReporter.report(e, st, kind: 'secure-screen');
      return false;
    } on PlatformException catch (e, st) {
      ErrorReporter.report(e, st, kind: 'secure-screen');
      return false;
    }
  }
}
