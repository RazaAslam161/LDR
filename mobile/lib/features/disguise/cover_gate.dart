import 'package:flutter/material.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fcm_service.dart';
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

  @override
  void initState() {
    super.initState();
    // Every cover watches for a call, so none of them has to remember to.
    pendingCall.addListener(openForPendingCall);
    // The notification may have been tapped before this cover was built.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => openForPendingCall());
  }

  @override
  void dispose() {
    pendingCall.removeListener(openForPendingCall);
    super.dispose();
  }

  /// Open the door for an incoming call, without the hidden trigger.
  ///
  /// A closed app woken by a call used to be unanswerable. The cover replaces
  /// the whole app while showRealApp is false, so the router — and with it the
  /// call route and the shell that listens for [pendingCall] — does not exist.
  /// The phone rang, the user opened the app, and saw a news reader with no way
  /// to reach the call before the caller gave up.
  ///
  /// The trigger is skipped, NOT the lock: the user already declared intent by
  /// tapping a call notification, but nothing about this app is revealed until
  /// they pass the same biometric as always. A shoulder-surfer sees the cover
  /// and a nameless system prompt, exactly as before.
  void openForPendingCall() {
    if (_entering || pendingCall.value == null) return;
    runEntryGate(forCall: true);
  }

  /// Runs gates 2 and 3. Call from whatever hidden trigger the cover provides.
  Future<void> runEntryGate({bool forCall = false}) async {
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

      // The splash is a deliberate beat of delay — but not while someone is
      // ringing. 1.2s of branding against a caller who is counting seconds is
      // the wrong trade, and the shoulder-surfer argument does not apply when
      // the user is answering a call they were just notified about.
      if (!forCall) {
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
      }

      if (mounted) onCoverUnlocked();
    } finally {
      // Always clear both guards, even on early return or error — a stuck
      // guard would lock the user out of their own app permanently.
      MilesApp.authInProgress = false;
      _entering = false;
    }
  }
}
