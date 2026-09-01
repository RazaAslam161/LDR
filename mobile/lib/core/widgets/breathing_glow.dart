import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';

/// Wraps [child] in a slow "breathing" scale + colored-glow pulse, for focal,
/// romantic moments — a sealed capsule waiting to be opened, the partner's
/// presence ring.
///
/// The first version animated a [BoxShadow]'s blur radius, which re-rasters
/// the shadow every frame — exactly the animated-shadow cost motion.dart
/// names as the thing that drops frames on the low-end hardware this app is
/// sideloaded onto. The glow is now a STATIC radial gradient painted once
/// inside its own [RepaintBoundary]; only its transform and opacity animate,
/// which the compositor carries without a paint pass. Same halo, none of the
/// per-frame raster.
///
/// Usage:
///   BreathingGlow(color: MilesColors.blush, child: const SealOrb());
class BreathingGlow extends StatefulWidget {
  const BreathingGlow({
    required this.child, super.key,
    this.color = MilesColors.blush,
    this.period = MilesMotion.breath,
    this.minScale = 0.98,
    this.maxScale = 1.04,
  });

  final Widget child;
  final Color color;
  final Duration period;
  final double minScale;
  final double maxScale;

  @override
  State<BreathingGlow> createState() => _BreathingGlowState();
}

class _BreathingGlowState extends State<BreathingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period);
  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _c, curve: MilesMotion.breathe);

  /// How far the halo reaches past the child on each side. Matches the old
  /// shadow's worst case (blur 52 + spread) so no call site reads smaller.
  static const _reach = 56.0;

  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // off() is a live system setting: checked on every dependency turn, and
    // the finished state here is mid-breath — a present, calm glow — with
    // zero tickers, not a frozen extreme of the cycle.
    final off = MilesMotion.off(context);
    if (off && _running) {
      _c.stop();
      _c.value = 0.5;
      _running = false;
    } else if (!off && !_running) {
      _c.repeat(reverse: true);
      _running = true;
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glowScale =
        Tween<double>(begin: 0.9, end: 1.25).animate(_curve);
    final glowFade = Tween<double>(begin: 0.4, end: 1).animate(_curve);
    final childScale =
        Tween<double>(begin: widget.minScale, end: widget.maxScale)
            .animate(_curve);

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: -_reach,
          top: -_reach,
          right: -_reach,
          bottom: -_reach,
          child: IgnorePointer(
            child: ScaleTransition(
              scale: glowScale,
              child: FadeTransition(
                opacity: glowFade,
                child: RepaintBoundary(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // A halo with no content on it — the alpha-in-gradient
                      // class the opacity hygiene rule explicitly exempts.
                      gradient: RadialGradient(
                        colors: [
                          widget.color.withValues(alpha: 0.35),
                          widget.color.withValues(alpha: 0.12),
                          widget.color.withValues(alpha: 0),
                        ],
                        stops: const [0, 0.55, 1],
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
        ScaleTransition(scale: childScale, child: widget.child),
      ],
    );
  }
}
