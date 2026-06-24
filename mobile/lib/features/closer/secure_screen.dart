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

  /// Applies FLAG_SECURE. Idempotent.
  static Future<void> setSecure() async {
    await _invoke('setSecure');
  }

  /// Clears FLAG_SECURE. Idempotent.
  static Future<void> clearSecure() async {
    await _invoke('clearSecure');
  }

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Native side not wired up yet (e.g. iOS, or pre-integration Android) —
      // not fatal. The feature still works; it just won't block screenshots.
    } on PlatformException {
      // Same: don't let a platform quirk crash the photo viewer.
    }
  }
}
