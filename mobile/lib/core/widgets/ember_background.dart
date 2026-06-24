import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:miles/core/theme.dart';

/// The app's magical signature: a warm candle-glow gradient with slowly drifting
/// embers and a faint starfield, painted with a single CustomPainter. Subtle and
/// slow — it sits behind content and never competes with it.
///
/// Usage: EmberBackground(child: YourScreen())
class EmberBackground extends StatefulWidget {
  const EmberBackground({
    super.key,
    required this.child,
    this.embers = 14,
    this.stars = 34,
  });

  final Widget child;
  final int embers;
  final int stars;

  @override
  State<EmberBackground> createState() => _EmberBackgroundState();
}

class _EmberBackgroundState extends State<EmberBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 36))
        ..repeat();
  late final List<_Ember> _embers;
  late final List<_Star> _stars;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(11);
    _embers = List.generate(
      widget.embers,
      (_) => _Ember(
        x: rnd.nextDouble(),
        y0: rnd.nextDouble(),
        speed: 0.4 + rnd.nextDouble() * 0.9,
        size: 1.0 + rnd.nextDouble() * 2.2,
        sway: 0.01 + rnd.nextDouble() * 0.03,
        phase: rnd.nextDouble(),
      ),
    );
    _stars = List.generate(
      widget.stars,
      (_) => _Star(
        x: rnd.nextDouble(),
        y: rnd.nextDouble() * 0.7,
        size: 0.6 + rnd.nextDouble() * 1.3,
        base: 0.2 + rnd.nextDouble() * 0.5,
        speed: 0.4 + rnd.nextDouble() * 1.4,
        phase: rnd.nextDouble(),
        violet: rnd.nextDouble() < 0.25,
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(decoration: BoxDecoration(color: MilesColors.night)),
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              painter: _EmberPainter(t: _c.value, embers: _embers, stars: _stars),
              size: Size.infinite,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _Ember {
  _Ember({
    required this.x,
    required this.y0,
    required this.speed,
    required this.size,
    required this.sway,
    required this.phase,
  });
  final double x, y0, speed, size, sway, phase;
}

class _Star {
  _Star({
    required this.x,
    required this.y,
    required this.size,
    required this.base,
    required this.speed,
    required this.phase,
    required this.violet,
  });
  final double x, y, size, base, speed, phase;
  final bool violet;
}

class _EmberPainter extends CustomPainter {
  _EmberPainter({required this.t, required this.embers, required this.stars});
  final double t;
  final List<_Ember> embers;
  final List<_Star> stars;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rect = Offset.zero & size;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

    // Candle glow.
    final center = Offset(w * (0.5 + 0.03 * math.sin(t * 2 * math.pi)),
        h * (0.32 + 0.02 * math.cos(t * 2 * math.pi)));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: const [Color(0xFF3A1622), Color(0xFF1C0A10), MilesColors.nightDeep],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(
            Rect.fromCircle(center: center, radius: h * (0.95 + 0.08 * pulse))),
    );

    // Stars.
    for (final s in stars) {
      final tw = 0.45 +
          0.55 * math.sin((t * s.speed + s.phase) * 2 * math.pi);
      canvas.drawCircle(
        Offset(w * s.x, h * s.y),
        s.size,
        Paint()
          ..color = (s.violet ? MilesColors.star : MilesColors.starlight)
              .withValues(alpha: (s.base * tw).clamp(0.0, 1.0)),
      );
    }

    // Embers drifting up.
    for (final e in embers) {
      final prog = (e.y0 + 1 - (t * e.speed) % 1) % 1; // 1 → 0 upward
      final y = h * prog;
      final x = w * (e.x + e.sway * math.sin((t * 4 + e.phase) * 2 * math.pi));
      final fade = (math.sin(prog * math.pi)).clamp(0.0, 1.0); // dim at top/bottom
      final paint = Paint()
        ..color = MilesColors.emberSoft.withValues(alpha: 0.5 * fade)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawCircle(Offset(x, y), e.size, paint);
    }
  }

  @override
  bool shouldRepaint(_EmberPainter old) => old.t != t;
}
