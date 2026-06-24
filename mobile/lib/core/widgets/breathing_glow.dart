import 'package:flutter/material.dart';
import 'package:miles/core/theme.dart';

/// Wraps [child] in a slow (~4s) "breathing" scale + colored-glow pulse, for
/// focal, romantic moments — e.g. a sealed capsule waiting to be opened, or a
/// hero CTA. The glow is a soft colored shadow (never a hard grey one).
///
/// Usage:
///   BreathingGlow(color: MilesColors.blush, child: const SealOrb());
class BreathingGlow extends StatefulWidget {
  const BreathingGlow({
    super.key,
    required this.child,
    this.color = MilesColors.blush,
    this.period = const Duration(seconds: 4),
    this.minScale = 0.98,
    this.maxScale = 1.04,
    this.minGlow = 16,
    this.maxGlow = 52,
    this.borderRadius,
  });

  final Widget child;
  final Color color;
  final Duration period;
  final double minScale;
  final double maxScale;
  final double minGlow;
  final double maxGlow;

  /// Glow shape. Defaults to a near-circle so it haloes round focal elements.
  final BorderRadius? borderRadius;

  @override
  State<BreathingGlow> createState() => _BreathingGlowState();
}

class _BreathingGlowState extends State<BreathingGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period)
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
    final radius = widget.borderRadius ?? BorderRadius.circular(999);
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) {
        final t = curve.value;
        final scale =
            widget.minScale + (widget.maxScale - widget.minScale) * t;
        final glow = widget.minGlow + (widget.maxGlow - widget.minGlow) * t;
        return Transform.scale(
          scale: scale,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.18 + 0.27 * t),
                  blurRadius: glow,
                  spreadRadius: glow * 0.12,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
