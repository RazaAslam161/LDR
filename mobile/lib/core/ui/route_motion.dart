import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';

/// DissolveIn — the app-wide route transition (design-system.md §5), adapted
/// to the motion law: the spec's "outgoing blurs 0→6px" is an animated blur,
/// which the hygiene suite bans outright, so the outgoing page dims instead.
/// Opacity and transform only, both compositor-borne.
///
/// Wired once, as `pageTransitionsTheme` in [milesDarkTheme] — every one of
/// the ~45 `builder:` routes in router.dart inherits it without an edit, and
/// so does every imperative [MaterialPageRoute] push.
///
/// The incoming fade HOLDS for the first 30% (fade-through, matching
/// [TabDissolve]): most scaffolds are transparent down to the ember field,
/// and two pages both half-opaque over it read as a double exposure.
///
/// Animations off: the pixels snap (bare child) AND the route runs at
/// [Duration.zero] — the duration getters below are consulted per push by
/// MaterialRouteTransitionMixin, and without them a pop was a ~300ms dead
/// tap for remove-animations users while a "finished" ticker played nothing.
/// The getters have no BuildContext, so they read the platform's
/// accessibility features directly.
class DissolveInTransitionsBuilder extends PageTransitionsBuilder {
  const DissolveInTransitionsBuilder();

  static bool get _off => ui.PlatformDispatcher.instance
      .accessibilityFeatures.disableAnimations;

  @override
  Duration get transitionDuration =>
      _off ? Duration.zero : const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration =>
      _off ? Duration.zero : const Duration(milliseconds: 300);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Pixel-level off contract, independent of the duration getters above —
    // MediaQuery is the authority a test harness can also drive.
    if (MilesMotion.off(context)) return child;

    // drive(CurveTween), never CurvedAnimation: this builder runs on EVERY
    // transition frame (the route wraps it in a ListenableBuilder), and a
    // CurvedAnimation registers a status listener on its parent that only
    // dispose() removes — ~57 leaked objects per navigation, unbounded on
    // long-lived routes. Animatable chains evaluate lazily and register
    // nothing.
    final fadeIn = animation.drive(
      CurveTween(curve: const Interval(0.3, 1, curve: MilesMotion.enter)),
    );
    final rise = animation
        .drive(CurveTween(curve: MilesMotion.enter))
        .drive(Tween<Offset>(
          begin: const Offset(0, MilesMotion.rise),
          end: Offset.zero,
        ),);
    final dim = secondaryAnimation
        .drive(CurveTween(curve: MilesMotion.enter))
        .drive(Tween<double>(begin: 1, end: 0.85));

    return FadeTransition(
      opacity: fadeIn,
      child: FadeTransition(
        opacity: dim,
        child: AnimatedBuilder(
          animation: rise,
          builder: (context, inner) =>
              Transform.translate(offset: rise.value, child: inner),
          child: child,
        ),
      ),
    );
  }
}
