import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/wordmark.dart';

/// The moment between unlocking the cover and the real app appearing.
///
/// This used to play a bundled 2.7MB intro.mp4. The video cost a hardware H.264
/// decoder and a second render surface on every single entry — on an Android
/// 8.1 MTK device that surface came back zero-height and the app showed a black
/// screen it never recovered from. It also meant nobody could open the app
/// without waiting out a clip they had already seen.
///
/// A wordmark that fades up and hands over is the same beat with none of that:
/// no decoder, no second surface, no asset, and it is over in well under a
/// second. Tap to skip even that.
class IntroSplashScreen extends StatefulWidget {
  const IntroSplashScreen({required this.onComplete, super.key});

  /// Fired exactly once, when the splash finishes or the user taps through.
  final VoidCallback onComplete;

  @override
  State<IntroSplashScreen> createState() => _IntroSplashScreenState();
}

class _IntroSplashScreenState extends State<IntroSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MilesMotion.flicker,
  )..forward();

  bool _done = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _advance();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _advance() {
    if (_done) return;
    _done = true;
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    // Someone who has asked their phone to stop animating things has usually
    // asked for a reason — vestibular discomfort, or a device where every
    // animation is a stutter. Honour it by handing straight over rather than
    // playing a 900ms fade they did not ask for. Read here rather than in
    // initState because the setting can change while the app is alive.
    if (MilesMotion.off(context) && !_done) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _advance());
    }

    // FlickerWelcome: the mark catches like a wick — two brief dips on the
    // way up — while it rises and settles.
    final rise = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.75, curve: MilesMotion.enter),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      // The whole screen is the skip target, which is right — but without a
      // label it is an unnamed tappable rectangle to a screen reader, on the
      // first screen of the app.
      body: Semantics(
        button: true,
        label: 'Skip intro',
        child: GestureDetector(
        onTap: _advance,
        behavior: HitTestBehavior.opaque,
        child: EmberBackground(
          child: Center(
            child: FlickerReveal(
              drive: _c,
              child: AnimatedBuilder(
                animation: rise,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, MilesMotion.rise * (1 - rise.value)),
                  child: child,
                ),
                child: const Wordmark(size: 46, tagline: true),
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
