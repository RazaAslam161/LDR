import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// The bloom that lands on both phones at once when someone warms the room.
///
/// Mounted once at the app root so any screen can be warmed without knowing
/// this exists. It is the only thing in the app that is *shared* rather than
/// sent: nothing is stored, nothing arrives later, and there is no notification
/// to answer — if they are not looking at their screen right now, they miss it,
/// which is the point. It is presence, not a message.
class WarmthOverlay extends ConsumerStatefulWidget {
  const WarmthOverlay({super.key});

  @override
  ConsumerState<WarmthOverlay> createState() => _WarmthOverlayState();
}

class _WarmthOverlayState extends ConsumerState<WarmthOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(roomWarmthProvider, (_, __) {
      MilesSound.cue(Cue.glow);
      _c.forward(from: 0); // from: 0 so a second warmth restarts, not stacks
    });

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            if (!_c.isAnimating) return const SizedBox.shrink();
            final t = _c.value;
            // Swell fast, fade slow — a breath on glass, not a flash.
            final intensity = t < 0.25
                ? Curves.easeOut.transform(t / 0.25)
                : 1 - Curves.easeInCubic.transform((t - 0.25) / 0.75);
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  // Anchored where the avatar sits, so the warmth reads as
                  // coming from them rather than from the system.
                  center: const Alignment(0.72, -0.92),
                  radius: 0.6 + t * 1.5,
                  colors: [
                    MilesColors.blush.withValues(alpha: 0.30 * intensity),
                    MilesColors.ember.withValues(alpha: 0.14 * intensity),
                    const Color(0x00000000),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
  }
}
