import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sets/clears Android's `FLAG_SECURE` on the current activity window.
///
/// `FLAG_SECURE` prevents the surface from appearing in screenshots, screen
/// recordings, and the recent-apps preview — used inside Private Vault photo
/// views and Memory Threads per the intimacy spec.
///
/// Behaviour:
/// - On Android, this calls into the `miles` native method channel. The native
///   side is a no-op until wired up in MainActivity — see README.
/// - On iOS there's no equivalent at the platform level, so the call is a no-op.
/// - Any platform-channel failure is swallowed (logged to debug console) so a
///   missing native hook never breaks a release build.
class SecureScreen {
  SecureScreen._();

  static const _channel = MethodChannel('miles/secure_screen');

  /// Whether FLAG_SECURE is currently applied. Last-call-wins, exactly like the
  /// native flag it mirrors.
  ///
  /// Read by the screen-share banner. Android blanks a FLAG_SECURE window in
  /// MediaProjection output, so walking into the Vault or Memory Threads while
  /// sharing sends the partner a black rectangle. That is the correct privacy
  /// behaviour and is not changed here — but it used to happen in total
  /// silence, with neither person able to tell it from a broken share.
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Applies FLAG_SECURE. Idempotent. (Native `setSecure` reads `enable`.)
  static Future<void> setSecure() async {
    active.value = true;
    await _invoke('setSecure', {'enable': true});
  }

  /// Clears FLAG_SECURE. Idempotent.
  static Future<void> clearSecure() async {
    active.value = false;
    await _invoke('setSecure', {'enable': false});
  }

  static Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Native side not wired up yet (e.g. iOS, or pre-integration Android) —
      // not fatal. The feature still works; it just won't block screenshots.
    } on PlatformException {
      // Same: don't let a platform quirk crash the photo viewer.
    }
  }
}
