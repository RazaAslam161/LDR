import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:miles/core/mood.dart';

/// Renders a mood as its cute animated Noto-emoji (Lottie). Falls back to the
/// plain emoji glyph if the animation can't load.
class AnimatedMood extends StatelessWidget {
  const AnimatedMood({
    super.key,
    required this.mood,
    this.size = 40,
    this.repeat = true,
  });

  final MoodData mood;
  final double size;
  final bool repeat;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Lottie.asset(
        mood.lottieAsset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        repeat: repeat,
        errorBuilder: (_, __, ___) => Center(
          child: Text(mood.emoji, style: TextStyle(fontSize: size * 0.82)),
        ),
      ),
    );
  }
}
