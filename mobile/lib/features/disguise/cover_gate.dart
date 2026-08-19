import 'package:flutter/material.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
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
    // Every cover watches for a call and for an auth link, so none of them has
    // to remember to.
    pendingCall.addListener(openForPendingCall);
    pendingAuthLink.addListener(openForAuthLink);
    // Either may have arrived before this cover was built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      openForPendingCall();
      openForAuthLink();
    });
  }

  @override
  void dispose() {
    pendingCall.removeListener(openForPendingCall);
    pendingAuthLink.removeListener(openForAuthLink);
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
  ///
  /// That premise only holds when the ring was actually tapped, and it was not
  /// checked. A push arriving while the app is foregrounded goes to
  /// FcmService._onForeground, which posts no notification at all — so on a
  /// handset sitting on its cover (where this app lands after every background,
  /// main.dart:269-271) the partner pressing Call used to replace the cover
  /// with the call screen, showing their avatar and real name, within a frame
  /// and with nothing tapped. With a lock enrolled it was quieter and still
  /// wrong: a biometric prompt raised by the other person, not by the user.
  ///
  /// So the door opens only on [CallTap.fromTap]. An untapped ring is left for
  /// the notification _onForeground posts instead; the shell's own listener is
  /// independent of this gate, so a ring arriving while the real app is already
  /// visible still reaches the controller unchanged.
  void openForPendingCall() {
    final tap = pendingCall.value;
    if (_entering || tap == null || !tap.fromTap) return;
    runEntryGate(forCall: true);
  }

  /// Open the door for an email confirmation or password-reset link.
  ///
  /// The same hole as [openForPendingCall], reached a different way. Reading
  /// the mail backgrounds this app, which drops it to the cover; tapping the
  /// link wakes it there. supabase_flutter redeems the token off that link and
  /// the session goes valid — behind a calculator, with nothing on screen to
  /// say so and, for a reset, no /new-password route in existence to push.
  ///
  /// Consumed on the first attempt rather than on success, so a failed
  /// biometric returns to the cover instead of re-prompting on every rebuild.
  /// The hidden trigger still works; the intent was one-shot.
  void openForAuthLink() {
    if (_entering || !pendingAuthLink.value) return;
    pendingAuthLink.value = false;
    runEntryGate();
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
      final passed = !enabled || await AppLock.authenticate();
      MilesApp.authInProgress = false;

      if (!passed || !mounted) return;

      // The splash is a deliberate beat of delay — but not while someone is
      // ringing. 1.2s of branding against a caller who is counting seconds is
      // the wrong trade, and the shoulder-surfer argument does not apply when
      // the user is answering a call they were just notified about.
      if (!forCall) {
        await Navigator.of(context).push(
          PageRouteBuilder<void>(
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

/// The way back, named — attached to something the cover already draws.
///
/// This replaces a small unlabelled ring that used to sit on every cover. On a
/// weather app a bare circle is the one thing worth tapping and it tells
/// whoever taps it nothing: conspicuous to a stranger, useless to the owner.
/// So nothing is drawn any more. An element the cover already renders — its own
/// title, a masthead, a location line — gains an `onTap`, and there is no new
/// pixel to notice.
///
/// One rule, nine covers: **a single tap on the app's own name.** Where the
/// cover shows no name (weather, calculator) it is the largest inert reading on
/// the screen instead. Never a long-press — that shape belongs to the hidden
/// doors ([DisguiseProfile.entry]), and a second long-press beside them is how
/// a user finds the first one by accident.
///
/// What opens is a plain About sheet: the app's real name, and THIS cover's
/// return gesture read from [profileForCover] rather than restated here, so the
/// picker's promise and the cover's reminder cannot drift apart. A forgotten
/// gesture used to be a lockout with no recovery short of a reinstall, and a
/// lockout is the one failure a cover is never allowed to have.
///
/// Printing the gesture costs nothing a stranger can spend: App Lock is a
/// precondition for applying a cover at all (gate 2 below, enforced by the
/// picker and re-asked by the shell), so knowing the gesture still ends at a
/// biometric prompt. Knowledge is not the guard; the lock is.
///
/// The `theme` is the cover's own `coverTheme`, passed rather than read from
/// `Theme.of(context)`: the covers that build one do it INSIDE `build`, so the
/// state's context sits above it and would hand back the host's stock blue
/// (main.dart's cover [MaterialApp]) instead. Covers that have no theme of
/// their own build one here — a sheet in Miles's own colours on top of a stock
/// utility is the tell `cover_theme.dart` exists to prevent.
/// The door itself: [child] gains a tap without gaining a pixel.
///
/// The 48dp box is Material's minimum tap target. Every label these hang on is
/// a single line of 13-20pt text, so its own glyph box is around 20dp tall —
/// thin for the one control an owner locked out of their app has to find a
/// month later, and free to widen because an AppBar's toolbar is 56dp already.
/// [Align.widthFactor] keeps the width shrink-wrapped: an AppBar title that
/// expanded would swallow taps across the whole bar.
class CoverAboutTap extends StatelessWidget {
  const CoverAboutTap({required this.onTap, required this.child, super.key});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Align(widthFactor: 1, child: child),
        ),
      );
}

Future<void> showCoverAbout(
  BuildContext context, {
  required DisguiseCover cover,
  required VoidCallback onOpen,
  required ThemeData theme,
}) {
  final entry = profileForCover(cover).entry;

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surface,
    // The Open button is last, and the column is as tall as the gesture text
    // makes it. Left at the default 9/16-of-screen cap this sheet clips its
    // own button off the bottom at large font scales — the one control the
    // panel exists to offer, gone for exactly the users most likely to need
    // it. Scroll-controlled sizes to content; the scroll view catches the
    // rest.
    isScrollControlled: true,
    builder: (sheetContext) => Theme(
      // The cover's palette, not the host's — and coverTheme leaves textTheme
      // alone, which is what keeps the sheet in the system font.
      data: theme,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The app's real name and this cover's gesture, and nothing
                // else. An earlier draft also explained that the screen was a
                // cover and why the launcher disagreed — which named the
                // mechanism, not just the app, to anyone who opened this.
                Text('Miles', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 20),
                Text('To open Miles', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(entry, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    // Pop first: the gate pushes the intro splash onto this
                    // navigator, and it must not land under a sheet.
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      onOpen();
                    },
                    child: const Text('Open Miles'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
