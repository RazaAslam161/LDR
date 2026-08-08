import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/theme.dart';

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
        style: GoogleFonts.fraunces(
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
          style: GoogleFonts.inter(
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
