import 'package:flutter/material.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_press.dart';

/// Pill CTA with a soft colored glow halo, the house pressed-state, and a
/// light haptic on touch. The glow is a colored shadow (never a hard grey
/// one) and it is STATIC: the first version animated its blur radius from
/// 22 to 36 across the press, which re-rasterized the shadow on every frame
/// of every tap on the app's most-used control — the exact cost
/// `motion.dart` bans. The scale and the haptic carry the acknowledgment,
/// exactly as they do everywhere else.
///
/// The press itself is [EmberPress] rather than a controller of its own:
/// one press idiom for the whole app, and `MilesMotion.off()` handled in one
/// place instead of eleven.
///
/// Usage: GlowButton(label: 'Send', color: MilesColors.blush, onPressed: ...)
class GlowButton extends StatelessWidget {
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

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    return EmberPress(
      onTap: _enabled ? onPressed : null,
      pressedScale: 0.96,
      onCue: () => MilesSound.cue(Cue.tap),
      child: Opacity(
        opacity: _enabled ? 1 : 0.5,
        child: Container(
          height: 56,
          width: expand ? double.infinity : null,
          alignment: Alignment.center,
          padding:
              expand ? null : const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(color, MilesColors.emberSoft, 0.25)!,
                color,
                Color.lerp(color, MilesColors.nightDeep, 0.25)!,
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            border:
                Border.all(color: MilesColors.gilt.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.38),
                blurRadius: 22,
                spreadRadius: 1,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: loading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: MilesColors.cream50,),)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: MilesColors.cream50),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      label,
                      style: const TextStyle(
                          color: MilesColors.cream50,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
