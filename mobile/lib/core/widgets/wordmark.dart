import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';

/// FlickerWelcome (design-system.md §5): the wordmark arrives like a wick
/// catching — rising brightness with two brief dips before it holds steady.
/// Opacity only, mapped from a caller-owned drive so the splash (and later
/// the sign-in title) can run it off whatever controller already times the
/// screen. With animations off, callers hold their drive at 1 and this
/// renders the finished mark.
class FlickerReveal extends StatelessWidget {
  const FlickerReveal({required this.drive, required this.child, super.key});

  final Animation<double> drive;
  final Widget child;

  /// Two ~40ms dips on the way up. Weights are per-mille of the drive; at
  /// [MilesMotion.flicker]'s 1100ms each dip is ~44ms — a candle stutter,
  /// not a strobe.
  static final Animatable<double> _flicker = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: 0.55), weight: 30),
    TweenSequenceItem(tween: Tween(begin: 0.55, end: 0.25), weight: 4),
    TweenSequenceItem(tween: Tween(begin: 0.25, end: 0.8), weight: 22),
    TweenSequenceItem(tween: Tween(begin: 0.8, end: 0.45), weight: 4),
    TweenSequenceItem(tween: Tween(begin: 0.45, end: 1), weight: 40),
  ]);

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: drive.drive(_flicker), child: child);
}

/// The app's name, set once so it reads the same everywhere it appears.
///
/// Fraunces italic with a warm vertical wash through the letterforms — the same
/// candlelight the rest of the app is lit by. It carries `TextDecoration.none`
/// explicitly because this is drawn in places with no Material ancestor (the
/// splash, overlays), where Flutter's fallback debug style would otherwise put
/// a yellow underline through the brand.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 28, this.tagline = false});

  final double size;

  /// Show the line under the name. Off by default — it belongs on the splash,
  /// not in a header.
  final bool tagline;

  @override
  Widget build(BuildContext context) {
    final name = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [MilesColors.cream50, MilesColors.gilt],
      ).createShader(bounds),
      child: Text(
        'Miles',
        textAlign: TextAlign.center,
        // One line, always. Left to soft-wrap it broke mid-word under squeeze
        // and grew the header vertically instead of giving ground.
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: MilesType.fraunces(
          fontSize: size,
          fontStyle: FontStyle.italic,
          fontWeight: FontWeight.w400,
          height: 1.1,
          letterSpacing: size * 0.01,
          color: MilesColors.cream50, // the shader paints over this
          decoration: TextDecoration.none,
        ),
      ),
    );

    if (!tagline) return name;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        name,
        const SizedBox(height: 10),
        Text(
          'your love, closer than distance',
          textAlign: TextAlign.center,
          style: MilesType.inter(
            fontSize: size * 0.28,
            letterSpacing: 0.4,
            color: MilesColors.taupe,
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}
