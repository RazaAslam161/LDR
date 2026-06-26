import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
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
    this.blur = 16,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? tint;

  /// Optional soft outer glow color.
  final Color? glow;

  /// BackdropFilter blur sigma. Default 16; raise for heavier frost.
  final double blur;

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
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
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

/// Frosted glass app-bar surface. Drop inside Scaffold.extendBodyBehindAppBar
/// + SliverAppBar(flexibleSpace: GlassAppBar(...)). Translucent, blurred, with
/// a 1px gilt hairline along the bottom.
class GlassAppBar extends StatelessWidget {
  const GlassAppBar({super.key, this.child, this.height = 64});
  final Widget? child;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: MilesColors.night.withValues(alpha: 0.55),
            border: Border(
              bottom: BorderSide(
                color: MilesColors.gilt.withValues(alpha: 0.12),
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Frosted-glass bottom navigation bar wrapper. Pass the child NavigationBar.
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: MilesColors.night.withValues(alpha: 0.72),
            border: Border(
              top: BorderSide(
                color: MilesColors.gilt.withValues(alpha: 0.12),
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Frosted-glass circular icon button — for floating actions, chrome.
class GlassCircleButton extends StatelessWidget {
  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.iconColor = MilesColors.cream50,
    this.size = 44,
    this.iconSize = 20,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final Color iconColor;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: MilesColors.surface2.withValues(alpha: 0.55),
          shape: const CircleBorder(
            side: BorderSide(color: MilesColors.gilt, width: 0.8),
          ),
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child:
                  Icon(icon, color: iconColor, size: iconSize),
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted-glass list tile row — for settings, drawers, action sheets.
class GlassTile extends StatelessWidget {
  const GlassTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.iconColor = MilesColors.gilt,
    this.dangerous = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color iconColor;
  final bool dangerous;

  @override
  Widget build(BuildContext context) {
    final labelColor = dangerous ? MilesColors.ember : MilesColors.cream50;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: MilesColors.surface2.withValues(alpha: 0.45),
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: MilesColors.gilt.withValues(alpha: 0.1)),
              ),
              child: Row(
                children: [
                  Icon(icon, color: iconColor, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: GoogleFonts.inter(
                        color: labelColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted-glass floating pill — used for HUD chips (distance, freshness).
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.radius = 24,
    this.blur = 18,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: MilesColors.surfaceGlass,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
                color: MilesColors.gilt.withValues(alpha: 0.18)),
          ),
          child: child,
        ),
      ),
    );
  }
}
