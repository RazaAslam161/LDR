import 'package:flutter/material.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';

import 'package:miles/features/breath/breath_sync_screen.dart'
    show BreathPhase;

/// OrbBreathe — the breathing pacer's orb (design-system.md §5).
///
/// The first orb resized its Container per frame: a LAYOUT pass every tick of
/// a 4-second animation, on the one screen whose entire job is smoothness.
/// This one owns a fixed 240px box and everything moves by Transform inside
/// it: a soft halo that swells and brightens with the breath, and a hot core
/// (MilesGradients.orb) that warms at the peak by cross-fading a second,
/// hotter static layer — opacity and transform only.
///
/// The [controller] is the screen's phase-retimed pulse (4s in / hold / 8s
/// out); [phase] names where in the cycle it is. With animations off the orb
/// renders each phase's FINISHED state (peak on inhale/hold, rest on exhale)
/// — the phase label above it carries the pacing for a user who asked motion
/// to stop.
class BreathOrb extends StatelessWidget {
  const BreathOrb({required this.controller, required this.phase, super.key});

  final AnimationController controller;
  final BreathPhase phase;

  static const double _box = 240;

  @override
  Widget build(BuildContext context) {
    if (phase == BreathPhase.idle) {
      return SizedBox.square(
        dimension: _box,
        child: Center(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: MilesGradients.halo,
            ),
            child: const SizedBox.square(
              dimension: 120,
              child: Icon(Icons.air, color: MilesColors.emberSoft, size: 40),
            ),
          ),
        ),
      );
    }

    final off = MilesMotion.off(context);
    return SizedBox.square(
      dimension: _box,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final v = off
              ? (phase == BreathPhase.exhale ? 0.0 : 1.0)
              : MilesMotion.breathe.transform(controller.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              // The halo: swells and brightens with the lungs.
              Transform.scale(
                scale: 0.9 + 0.5 * v,
                child: Opacity(
                  opacity: 0.35 + 0.45 * v,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: MilesGradients.halo,
                    ),
                    child: SizedBox.square(dimension: 160),
                  ),
                ),
              ),
              // The core, and its hotter twin fading in at the peak.
              Transform.scale(
                scale: 1.0 + 0.5 * v,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: MilesGradients.orb,
                      ),
                      child: SizedBox.square(dimension: 96),
                    ),
                    Opacity(
                      opacity: v,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              MilesColors.starlight,
                              MilesColors.emberSoft,
                              Color(0x00C84B6A),
                            ],
                            stops: [0.0, 0.45, 1.0],
                          ),
                        ),
                        child: SizedBox.square(dimension: 96),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
