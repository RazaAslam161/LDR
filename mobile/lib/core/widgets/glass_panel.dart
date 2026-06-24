import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:miles/core/theme.dart';

/// Frosted glass card — a BackdropFilter blur under a warm translucent tint
/// with a 1px gilt hairline. The candlelit "velvet" surface.
///
/// Usage: GlassPanel(child: ...)
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 24,
    this.tint,
    this.glow,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? tint;

  /// Optional soft outer glow color.
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: border,
        shadows: glow == null
            ? null
            : [
                BoxShadow(
                  color: glow!.withValues(alpha: 0.22),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  (tint ?? MilesColors.surface2).withValues(alpha: 0.78),
                  (tint ?? MilesColors.surface1).withValues(alpha: 0.70),
                ],
              ),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: MilesColors.gilt.withValues(alpha: 0.16),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
