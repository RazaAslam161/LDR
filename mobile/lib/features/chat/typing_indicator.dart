import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:miles/core/theme.dart';

/// Three gently bouncing dots — shown when the partner is typing.
class TypingIndicator extends StatelessWidget {
  const TypingIndicator({super.key, this.color = MilesColors.sage});
  final Color color;

  @override
  Widget build(BuildContext context) {
    Widget dot(int i) => Container(
          width: 5,
          height: 5,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ).animate(onPlay: (c) => c.repeat(reverse: true)).moveY(
              begin: 0,
              end: -3,
              duration: 400.ms,
              delay: (i * 150).ms,
              curve: Curves.easeInOut,
            );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [dot(0), dot(1), dot(2)],
    );
  }
}
