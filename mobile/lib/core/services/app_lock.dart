import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:miles/core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional biometric (fingerprint / face / device PIN) lock for the whole app.
/// When enabled, the app locks on launch and whenever it's backgrounded; the
/// user must authenticate to get back in.
class AppLock {
  AppLock._();

  static const _key = 'app_lock_enabled';
  static final _auth = LocalAuthentication();

  /// Whether the lock overlay should currently cover the app.
  static final ValueNotifier<bool> locked = ValueNotifier<bool>(false);

  static Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
    if (!value) locked.value = false;
  }

  /// Can this device actually do biometric / device-credential auth?
  static Future<bool> canAuthenticate() async {
    try {
      return await _auth.isDeviceSupported() || await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  /// Raise the lock (call on launch + when the app backgrounds).
  static Future<void> lockIfEnabled() async {
    if (await isEnabled()) locked.value = true;
  }

  /// Prompt for biometrics; on success, drop the lock.
  static Future<void> tryUnlock() async {
    if (!locked.value) return;
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock Tethered',
        options: const AuthenticationOptions(stickyAuth: true),
      );
      if (ok) locked.value = false;
    } catch (_) {
      // user cancelled / no biometrics — stay locked, they can retry
    }
  }
}

/// Full-screen lock shown over the app while [AppLock.locked] is true.
class LockOverlay extends StatelessWidget {
  const LockOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: MilesColors.night,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_rounded,
                  color: MilesColors.ember, size: 56),
              const SizedBox(height: 16),
              const Text('Tethered is locked',
                  style: TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text('Unlock to continue',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 13)),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: AppLock.tryUnlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
