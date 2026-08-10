import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/theme.dart';

/// Pill CTA with a soft colored glow halo, a pressed-state scale, and a light
/// haptic on tap. Glow is a colored shadow (never a hard grey one).
///
/// Usage: GlowButton(label: 'Send', color: MilesColors.blush, onPressed: ...)
class GlowButton extends StatefulWidget {
  const GlowButton({
    required this.label, super.key,
    this.onPressed,
    this.icon,
    this.color = MilesColors.ember,
    this.expand = true,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;
  final bool expand;
  final bool loading;

  @override
  State<GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<GlowButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _enabled ? _c.forward() : null,
      onTapUp: (_) => _c.reverse(),
      onTapCancel: () => _c.reverse(),
      onTap: _enabled
          ? () {
              HapticFeedback.lightImpact();
              widget.onPressed!.call();
            }
          : null,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final pressed = _c.value;
          return Transform.scale(
            scale: 1 - 0.04 * pressed,
            child: Opacity(
              opacity: _enabled ? 1 : 0.5,
              child: Container(
                height: 56,
                width: widget.expand ? double.infinity : null,
                alignment: Alignment.center,
                padding: widget.expand
                    ? null
                    : const EdgeInsets.symmetric(horizontal: 28),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(widget.color, MilesColors.emberSoft, 0.25)!,
                      widget.color,
                      Color.lerp(widget.color, MilesColors.nightDeep, 0.25)!,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                      color: MilesColors.gilt.withValues(alpha: 0.14),),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.38),
                      blurRadius: 22 + 14 * pressed,
                      spreadRadius: 1,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: child,
              ),
            ),
          );
        },
        child: widget.loading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: MilesColors.cream50,),)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 18, color: MilesColors.cream50),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.label,
                    style: const TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,),
                  ),
                ],
              ),
      ),
    );
  }
}
