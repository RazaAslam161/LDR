import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lottie/lottie.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/theme.dart';

/// A luxury, velvety intro shown on launch — Fraunces serif, gilt shimmer, a
/// cute animated heart. It lingers until the biometric unlock is done (with a
/// minimum so it's always readable), then fades away. Tap to skip.
class IntroSplash extends StatefulWidget {
  const IntroSplash({super.key});

  @override
  State<IntroSplash> createState() => _IntroSplashState();
}

class _IntroSplashState extends State<IntroSplash>
    with TickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..forward();
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat();

  double _opacity = 1;
  bool _gone = false;
  bool _minPassed = false;
  Timer? _minTimer;
  Timer? _maxTimer;

  @override
  void initState() {
    super.initState();
    // Readable minimum, then leave as soon as the app is unlocked.
    _minTimer = Timer(const Duration(milliseconds: 5000), () {
      _minPassed = true;
      _maybeDismiss();
    });
    // Hard safety cap so it can never stick around.
    _maxTimer = Timer(const Duration(milliseconds: 12000), _dismiss);
    AppLock.locked.addListener(_maybeDismiss);
  }

  void _maybeDismiss() {
    if (!_minPassed) return;
    if (!AppLock.locked.value) _dismiss();
  }

  void _dismiss() {
    if (_gone || !mounted) return;
    setState(() => _opacity = 0);
    Timer(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  void dispose() {
    _minTimer?.cancel();
    _maxTimer?.cancel();
    AppLock.locked.removeListener(_maybeDismiss);
    _reveal.dispose();
    _glow.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  // A staggered fade + gentle rise for each line.
  Widget _stagger(double start, double end, Widget child) {
    final anim = CurvedAnimation(
      parent: _reveal,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, c) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
            offset: Offset(0, (1 - anim.value) * 16), child: c),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 850),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: () {
            _minPassed = true;
            _dismiss();
          },
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.25),
                radius: 1.3,
                colors: [
                  Color(0xFF3A1622),
                  Color(0xFF1C0A10),
                  MilesColors.nightDeep,
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
            child: Stack(
              children: [
                // faint gilt sparkles for a touch of luxe
                ..._sparkles(),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Spacer(flex: 5),
                        _stagger(0.0, 0.4, _ornament()),
                        const SizedBox(height: 22),
                        _stagger(
                          0.12,
                          0.55,
                          Text(
                            'Built for the love of my life',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.fraunces(
                              fontSize: 19,
                              fontWeight: FontWeight.w400,
                              fontStyle: FontStyle.italic,
                              height: 1.4,
                              letterSpacing: 0.2,
                              color: MilesColors.cream100,
                            ),
                          ),
                        ),
                        const SizedBox(height: 30),
                        _stagger(0.25, 0.7, _heart()),
                        const SizedBox(height: 30),
                        _stagger(0.4, 0.85, _shimmerName()),
                        const Spacer(flex: 5),
                        _stagger(0.6, 1.0, _credit()),
                        const Spacer(flex: 1),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ornament() {
    Widget line() => Container(
          width: 46,
          height: 1,
          color: MilesColors.gilt.withValues(alpha: 0.45),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        line(),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text('✦',
              style: TextStyle(color: MilesColors.gilt, fontSize: 12)),
        ),
        line(),
      ],
    );
  }

  Widget _heart() {
    return AnimatedBuilder(
      animation: _glow,
      builder: (_, child) {
        final g = 0.55 + _glow.value * 0.45;
        return Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: MilesColors.blush.withValues(alpha: 0.42 * g),
                blurRadius: 46 + 24 * g,
                spreadRadius: 6,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Lottie.asset(
        'assets/emoji/heart.json',
        width: 132,
        height: 132,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.favorite, color: MilesColors.blush, size: 96),
      ),
    );
  }

  /// "My Forever" in Fraunces gold with a moving light sweep across it.
  Widget _shimmerName() {
    final text = Text(
      'My Forever',
      textAlign: TextAlign.center,
      style: GoogleFonts.fraunces(
        fontSize: 52,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        height: 1.05,
        color: MilesColors.gilt,
      ),
    );
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (_, child) {
        final t = _shimmer.value * 2 - 0.5; // sweep position
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(t - 0.45, 0),
            end: Alignment(t + 0.45, 0),
            colors: const [
              MilesColors.gilt,
              Color(0xFFFBE9C8),
              MilesColors.gilt,
            ],
            stops: const [0.30, 0.5, 0.70],
          ).createShader(rect),
          child: child,
        );
      },
      child: text,
    );
  }

  Widget _credit() {
    return Column(
      children: [
        Container(
          width: 34,
          height: 1,
          color: MilesColors.gilt.withValues(alpha: 0.4),
        ),
        const SizedBox(height: 16),
        Text(
          'DEVELOPED BY HER HUSBAND',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 3.0,
            color: MilesColors.taupe,
          ),
        ),
      ],
    );
  }

  // A handful of softly twinkling gilt dots.
  List<Widget> _sparkles() {
    const spots = [
      [0.16, 0.20, 2.0],
      [0.82, 0.16, 1.6],
      [0.24, 0.74, 1.8],
      [0.78, 0.70, 2.2],
      [0.5, 0.12, 1.4],
      [0.12, 0.5, 1.5],
      [0.88, 0.46, 1.7],
    ];
    return [
      for (var i = 0; i < spots.length; i++)
        Align(
          alignment: Alignment(spots[i][0] * 2 - 1, spots[i][1] * 2 - 1),
          child: AnimatedBuilder(
            animation: _glow,
            builder: (_, __) {
              final phase = (i.isEven ? _glow.value : 1 - _glow.value);
              return Opacity(
                opacity: 0.15 + phase * 0.55,
                child: Container(
                  width: spots[i][2] * 2,
                  height: spots[i][2] * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: MilesColors.gilt,
                    boxShadow: [
                      BoxShadow(
                          color: MilesColors.gilt.withValues(alpha: 0.6),
                          blurRadius: 6),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
    ];
  }
}
