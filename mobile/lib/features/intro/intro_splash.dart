import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miles/core/theme.dart';

/// A romantic, velvety intro shown once per app launch. Fades in, glows, then
/// fades away (or tap to skip). A little love note before the app opens.
class IntroSplash extends StatefulWidget {
  const IntroSplash({super.key});

  @override
  State<IntroSplash> createState() => _IntroSplashState();
}

class _IntroSplashState extends State<IntroSplash>
    with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..forward();
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  double _opacity = 1;
  bool _gone = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 4400), _dismiss);
  }

  void _dismiss() {
    if (_gone || !mounted) return;
    setState(() => _opacity = 0);
    Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _in.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 750),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: _dismiss,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.18),
                radius: 1.25,
                colors: [
                  Color(0xFF4A1426),
                  Color(0xFF2A0A1B),
                  MilesColors.night,
                ],
                stops: [0.0, 0.5, 1.0],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 34, vertical: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(flex: 3),
                    FadeTransition(
                      opacity: CurvedAnimation(
                        parent: _in,
                        curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
                      ),
                      child: const Text(
                        'Built for the love of my life',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: MilesColors.cream50,
                          fontSize: 18,
                          height: 1.4,
                          letterSpacing: 0.4,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                    const SizedBox(height: 26),
                    AnimatedBuilder(
                      animation: _glow,
                      builder: (_, __) {
                        final g = 0.55 + _glow.value * 0.45;
                        return Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: MilesColors.blush
                                    .withValues(alpha: 0.55 * g),
                                blurRadius: 40 + 26 * g,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.favorite,
                            size: 66,
                            color: Color.lerp(MilesColors.blush,
                                MilesColors.ember, _glow.value),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 28),
                    ScaleTransition(
                      scale: CurvedAnimation(
                        parent: _in,
                        curve:
                            const Interval(0.3, 1.0, curve: Curves.easeOutBack),
                      ),
                      child: FadeTransition(
                        opacity: CurvedAnimation(
                          parent: _in,
                          curve: const Interval(0.3, 0.9),
                        ),
                        child: const Text(
                          'Mrs Raza',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: MilesColors.gilt,
                            fontSize: 48,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.0,
                            shadows: [
                              Shadow(
                                color: MilesColors.gilt,
                                blurRadius: 24,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Spacer(flex: 4),
                    FadeTransition(
                      opacity: CurvedAnimation(
                        parent: _in,
                        curve: const Interval(0.55, 1.0, curve: Curves.easeOut),
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 44,
                            height: 1,
                            color: MilesColors.gilt.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'developed by her husband',
                            style: TextStyle(
                              color: MilesColors.taupe,
                              fontSize: 13,
                              letterSpacing: 1.6,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '♥',
                            style: TextStyle(
                                color: MilesColors.blush, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(flex: 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
