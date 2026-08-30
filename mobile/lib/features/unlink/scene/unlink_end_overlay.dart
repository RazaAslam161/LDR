import 'package:flutter/material.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';

/// How a ceremony ends, seen for one breath over the whole app.
enum UnlinkEnding {
  /// The door opened from inside: warm light floods, then the app is back.
  relink,

  /// The lamp dies and the night takes the street: dark rises, then lifts on
  /// whatever screen comes next.
  ended,
}

/// The ritual's two endings, played ABOVE the router.
///
/// They cannot live in the ritual screen: both endings navigate, navigation
/// unmounts the screen mid-flight, and a farewell cut off halfway is worse
/// than none. So this sits in the root builder Stack beside WarmthOverlay,
/// survives every route change, and is triggered by one static notifier set
/// SYNCHRONOUSLY in the teardown path — the pinned sequence there gains no
/// await, because the wipe plays OVER the teardown, never instead of it.
///
/// WarmthOverlay's laws, all of them: IgnorePointer always (an ending must
/// never eat a tap), RepaintBoundary inside the Positioned slot (the
/// ParentDataWidget outage precedent), `SizedBox.shrink` the instant the
/// controller rests, and with animations off nothing plays at all — the
/// navigation IS the ending.
class UnlinkEndOverlay extends StatefulWidget {
  const UnlinkEndOverlay({super.key});

  /// Set it and walk away; the overlay consumes it. Null after every play.
  static final ValueNotifier<UnlinkEnding?> play =
      ValueNotifier<UnlinkEnding?>(null);

  @override
  State<UnlinkEndOverlay> createState() => _UnlinkEndOverlayState();
}

class _UnlinkEndOverlayState extends State<UnlinkEndOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: MilesMotion.floodOpen,
  );

  UnlinkEnding? _kind;

  @override
  void initState() {
    super.initState();
    UnlinkEndOverlay.play.addListener(_onPlay);
    _c.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _kind = null);
      }
    });
  }

  void _onPlay() {
    final kind = UnlinkEndOverlay.play.value;
    if (kind == null) return;
    UnlinkEndOverlay.play.value = null; // consumed
    // The ending's voice plays even when its light cannot (animations off):
    // the door opening or the last latch, heard once, fire-and-forget.
    MilesSound.cue(kind == UnlinkEnding.relink ? Cue.unlock : Cue.seal);
    if (!mounted || MilesMotion.off(context)) return;
    setState(() => _kind = kind);
    _c
      ..duration = kind == UnlinkEnding.relink
          ? MilesMotion.floodOpen
          : MilesMotion.duskFall
      ..forward(from: 0);
  }

  @override
  void dispose() {
    UnlinkEndOverlay.play.removeListener(_onPlay);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final kind = _kind;
            if (kind == null || !_c.isAnimating) {
              return const SizedBox.shrink();
            }
            final t = _c.value;
            // Swell fast, fade slow — the WarmthOverlay envelope, because an
            // ending is a breath, not a flash.
            final intensity = t < 0.25
                ? MilesMotion.enter.transform(t / 0.25)
                : 1 - MilesMotion.strike.transform((t - 0.25) / 0.75);
            return kind == UnlinkEnding.relink
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.2, 0.35),
                        radius: 1.4,
                        colors: [
                          MilesColors.starlight
                              .withValues(alpha: 0.75 * intensity),
                          MilesColors.gilt.withValues(alpha: 0.35 * intensity),
                          MilesColors.gilt.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  )
                : ColoredBox(
                    color: MilesColors.nightDeep
                        .withValues(alpha: 0.9 * intensity),
                  );
          },
        ),
      ),
    );
  }
}
