import 'package:flutter/material.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/features/intro/intro_splash_screen.dart';
import 'package:miles/main.dart';

/// The way in, from behind any disguise.
///
/// No cover owns a door. The nine cover screens are fake apps and nothing
/// else; every way through them is decided here and driven from the host, so
/// the entry rules live once rather than being re-implemented (and re-broken)
/// per disguise:
///
///  1. **The owner's own move** — recorded on this cover from Settings and
///     matched by the host's pointer layer. The app ships no default gesture:
///     anything the app authored is in the APK and on the listing, and a door
///     everyone knows is not a door.
///  2. **The backup hold** — two still fingers on the cover's opening screen
///     for [kCoverRecoveryHold]. Public by design (it is the one sentence Play
///     Console gets), so with a move recorded it never opens the app on its
///     own: it lands on a nameless PIN screen.
///  3. **The app lock** — biometric, with the PIN as the fallback. Skipped only
///     when the user has never set one up, so a fresh install is not locked out
///     of its own app.
///  4. **The intro reveal** — the cinematic hand-off. Also a deliberate beat of
///     delay: a shoulder-surfer sees a brand splash, not the app.
///
/// Failure is silent by design. A wrong move, a wrong PIN, a dismissed prompt
/// all return to the cover with no error, no toast, no ripple — someone who
/// tripped a door by accident learns nothing, and someone probing gets no
/// signal they were close.

/// How long two still fingers stay down before the backup door opens.
const kCoverRecoveryHold = Duration(seconds: 5);

/// Who is asking the gate to open.
enum EntrySource {
  /// The move the owner recorded for this cover, matched by the host's layer.
  custom,

  /// The two-finger backup hold. Ends at the PIN whenever a move exists.
  backup,

  /// A tapped call notification or an auth link: intent the user already
  /// declared. Skips the trigger, never the lock.
  system,
}

/// What the host knows about the rendered cover's recorded move.
enum CoverEntryMode {
  /// Nothing recorded for this cover. Only the backup hold works, and it runs
  /// the ordinary lock — the exposure the old About sheet's button had.
  none,

  /// A move is loaded and the layer is matching it.
  custom,

  /// A move exists but could not be read (keystore pending or broken). The
  /// backup hold still works and still ends at the PIN.
  customUnknown,
}

/// Gates 3 and 4, run for every source by the host.
class CoverEntry {
  CoverEntry._();

  /// One entry flow at a time: two triggers firing together must not stack a
  /// second splash or double-fire the reveal. Static, because the host's layer
  /// and the system doors share it; the host resets it on mount, since a fresh
  /// host means no flow can be in progress on its navigator.
  static bool entering = false;

  static Future<void> run(
    BuildContext navContext, {
    required VoidCallback onUnlocked,
    required EntrySource source,
    required CoverEntryMode mode,
    bool forCall = false,
  }) async {
    if (entering) return;
    entering = true;
    try {
      // authInProgress stops the biometric prompt's own `inactive` lifecycle
      // event from dropping the cover out from under the prompt.
      MilesApp.authInProgress = true;
      final passed = await _passes(navContext, source: source, mode: mode);
      MilesApp.authInProgress = false;

      if (!passed || !navContext.mounted) return;

      // The splash is a deliberate beat of delay — but not while someone is
      // ringing. 1.2s of branding against a caller who is counting seconds is
      // the wrong trade, and the shoulder-surfer argument does not apply when
      // the user is answering a call they were just notified about.
      if (!forCall) {
        await Navigator.of(navContext).push(
          PageRouteBuilder<void>(
            pageBuilder: (_, __, ___) => IntroSplashScreen(
              onComplete: () => Navigator.of(navContext).pop(),
            ),
            transitionsBuilder: (_, anim, __, child) =>
                FadeTransition(opacity: anim, child: child),
          ),
        );
      }

      if (navContext.mounted) onUnlocked();
    } finally {
      // Always clear both guards, even on early return or error — a stuck
      // guard would lock the user out of their own app permanently.
      MilesApp.authInProgress = false;
      entering = false;
    }
  }

  /// Gate 3: biometric, WITH THE PIN AS THE FALLBACK.
  ///
  /// Never `AppLock.authenticate()`'s bool read as a verdict. That method's
  /// own documentation says false means "the caller falls back to the PIN",
  /// and a gate that once read it as a refusal locked a OnePlus 7 with no
  /// enrolled lock out of its own app: the trigger fired, no prompt appeared,
  /// and the cover simply stayed up. LockScreen is this app's real unlock
  /// surface — it prompts biometrics, lets the prompt be retried, and drops
  /// STRAIGHT to the PIN pad when no biometric is enrolled.
  static Future<bool> _passes(
    BuildContext navContext, {
    required EntrySource source,
    required CoverEntryMode mode,
  }) async {
    // The backup door is public knowledge, so with a move recorded it may not
    // open on its own: it ends at the PIN whether or not App Lock is switched
    // on. The owner's own move keeps App Lock's setting — with the lock off
    // the move opens the app directly, which is the owner's choice.
    final forced = source == EntrySource.backup && mode != CoverEntryMode.none;
    if (!forced && !await AppLock.isEnabled()) return true;
    final bio = await AppLock.availableBiometrics();
    final hasPin = await AppLock.hasPin();
    // Nothing on this device can EVER satisfy the lock. Refusing forever is a
    // lockout, not security: a lock with no key protects nobody, and the only
    // person it holds out is the owner. Let them through rather than hand them
    // a door that cannot open — and lower the flag on the way, or the real
    // app's own overlay (main.dart) raises the same keyless lock the moment
    // this returns.
    if (bio.isEmpty && !hasPin) {
      AppLock.locked.value = false;
      return true;
    }
    if (!navContext.mounted) return false;
    return _pushLock(navContext, nameless: forced);
  }

  /// Pushed rather than toggled, because the overlay that normally renders
  /// the lock (main.dart) belongs to the real app's tree, and that tree does
  /// not exist while a cover is up.
  static Future<bool> _pushLock(
    BuildContext navContext, {
    required bool nameless,
  }) async {
    final nav = Navigator.of(navContext);
    final wasLocked = AppLock.locked.value;
    AppLock.locked.value = true;
    void popWhenOpen() {
      // The cover tree can be torn down under a pending lock (a system door
      // lowering the cover, a process-level swap); a navigator that is gone
      // has nothing to pop.
      if (!nav.mounted) return;
      if (!AppLock.locked.value && nav.canPop()) nav.pop();
    }

    AppLock.locked.addListener(popWhenOpen);
    try {
      await nav.push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => LockScreen(nameless: nameless),
        ),
      );
    } finally {
      AppLock.locked.removeListener(popWhenOpen);
    }
    final open = !AppLock.locked.value;
    // The nameless screen can be backed out of, and the flag it raised must
    // not outlive it: the real app's overlay reads the same notifier, and a
    // later entry through the owner's move with App Lock off would otherwise
    // land on a lock screen nobody asked for.
    if (!open && nameless) AppLock.locked.value = wasLocked;
    return open;
  }
}
