import 'package:flutter/material.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/features/intro/intro_splash_screen.dart';
import 'package:miles/main.dart';

/// The way in, from behind any disguise.
///
/// Every cover screen fronts the same door, so the entry rules live here once
/// rather than being re-implemented (and re-broken) per disguise:
///
///  1. **A hidden trigger** the cover itself owns — five taps on a logo, a
///     secret search word, a long-press. Nothing on screen hints at it.
///  2. **The app lock** — biometric, with the PIN as the fallback. Skipped only
///     when the user has never set one up, so a fresh install is not locked out
///     of its own app.
///  3. **The intro reveal** — the cinematic hand-off. Also a deliberate beat of
///     delay: a shoulder-surfer sees a brand splash, not the app.
///
/// Failure is silent by design. A wrong biometric returns to the cover with no
/// error, no toast, no ripple — someone who tripped the trigger by accident
/// learns nothing, and someone probing gets no signal they were close.
mixin CoverGate<T extends StatefulWidget> on State<T> {
  /// One entry flow at a time: two triggers firing together must not stack a
  /// second splash or double-fire the reveal.
  bool _entering = false;

  /// Called once the user is through all three gates.
  void onCoverUnlocked();

  /// Runs gates 2 and 3. Call from whatever hidden trigger the cover provides.
  Future<void> runEntryGate() async {
    if (_entering) return;
    _entering = true;
    try {
      // authInProgress stops the biometric prompt's own `inactive` lifecycle
      // event from dropping the cover out from under the prompt.
      MilesApp.authInProgress = true;
      final enabled = await AppLock.isEnabled();
      final passed = enabled ? await AppLock.authenticate() : true;
      MilesApp.authInProgress = false;

      if (!passed || !mounted) return;

      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, __, ___) => IntroSplashScreen(
            onComplete: () => Navigator.of(context).pop(),
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );

      if (mounted) onCoverUnlocked();
    } finally {
      // Always clear both guards, even on early return or error — a stuck
      // guard would lock the user out of their own app permanently.
      MilesApp.authInProgress = false;
      _entering = false;
    }
  }
}
