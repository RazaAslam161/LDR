import 'package:flutter/material.dart';
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
    duration: const Duration(milliseconds: 900),
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
    // Rise and settle: the mark lifts a little as it fades in, then holds.
    final fade = CurvedAnimation(parent: _c, curve: const Interval(0, 0.6));
    final rise = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.75, curve: Curves.easeOutCubic),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: _advance,
        behavior: HitTestBehavior.opaque,
        child: EmberBackground(
          child: Center(
            child: FadeTransition(
              opacity: fade,
              child: AnimatedBuilder(
                animation: rise,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, 16 * (1 - rise.value)),
                  child: child,
                ),
                child: const Wordmark(size: 46, tagline: true),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
