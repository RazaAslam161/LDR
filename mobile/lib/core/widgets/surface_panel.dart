import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';

/// Solid surfaces, replacing the former frosted-glass ones.
///
/// Every one of these used to wrap its content in a `BackdropFilter`. That is
/// the most expensive thing this UI could do: it forces the compositor to read
/// back everything already painted behind the widget and blur it, every frame,
/// and the cost scales with both sigma and the area covered. With panels
/// stacked over an animated background it was paying that repeatedly per frame
/// on exactly the cheap phones this has to stay smooth on.
///
/// The opaque `surface1` / `surface2` tokens are the same colours the
/// translucent glass resolved to over the night background, so the layout and
/// contrast are unchanged — what is gone is the blur and the see-through.
///
/// The old GlassAppBar, GlassCircleButton and GlassTile went with the blur: they had no
/// call sites left.
class SurfacePanel extends StatelessWidget {
  const SurfacePanel({
    required this.child, super.key,
    this.padding = const EdgeInsets.all(20),
    this.radius = 18,
    this.color,
    this.borderColor,
    this.borderWidth = 0.8,
    this.elevated = false,
    this.glow,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final Color? borderColor;
  final double borderWidth;

  /// Picks the raised surface tone. Previously also selected a heavier blur.
  final bool elevated;

  /// Optional coloured drop shadow. This is a real shadow, not a backdrop
  /// effect, so it costs nothing like the blur did.
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (elevated ? MilesColors.surface2 : MilesColors.surface1);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: borderColor ?? MilesColors.hairline,
          width: borderWidth,
        ),
        boxShadow: glow == null
            ? null
            : [
                BoxShadow(
                  color: glow!.withValues(alpha: 0.22),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Solid bottom navigation surface. Pass the child NavigationBar.
class SurfaceNavBar extends StatelessWidget {
  const SurfaceNavBar({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: MilesColors.surface1,
        border: Border(
          top: BorderSide(color: Color(0x1FE8C49A)),
        ),
      ),
      child: child,
    );
  }
}

/// Solid floating pill — HUD chips (distance, freshness).
class SurfacePill extends StatelessWidget {
  const SurfacePill({
    required this.child, super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.radius = 24,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.18)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
