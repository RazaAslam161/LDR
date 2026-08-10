import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';

/// The app's magical signature: a warm candle-glow gradient with slowly drifting
/// embers and a faint starfield, painted with a single CustomPainter. Subtle and
/// slow — it sits behind content and never competes with it.
///
/// Usage: EmberBackground(child: YourScreen())
///
/// Nesting is free: `main.dart` mounts one app-wide, and a screen that wraps
/// itself in another gets a pass-through instead of a second painter. The inner
/// instance's opaque [MilesColors.night] fill hid the outer one completely, so
/// twelve screens were paying for a full-screen repaint every vsync that nobody
/// could see — on top of the root one that was still running underneath.
class EmberBackground extends StatefulWidget {
  const EmberBackground({
    required this.child, super.key,
    this.embers = 14,
    this.stars = 34,
  });

  final Widget child;
  final int embers;
  final int stars;

  @override
  State<EmberBackground> createState() => _EmberBackgroundState();
}

/// Marks that an ancestor is already painting the backdrop.
class _EmberBackgroundScope extends InheritedWidget {
  const _EmberBackgroundScope({required super.child});

  @override
  bool updateShouldNotify(_EmberBackgroundScope oldWidget) => false;
}

class _EmberBackgroundState extends State<EmberBackground>
    with SingleTickerProviderStateMixin {
  /// Null while nested — a pass-through must not run a ticker.
  AnimationController? _c;
  late final List<_Ember> _embers;
  late final List<_Star> _stars;
  bool _nested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read (don't depend on) the marker: it never changes value, only presence.
    final nested =
        context.getInheritedWidgetOfExactType<_EmberBackgroundScope>() != null;
    if (nested) {
      _c?.dispose();
      _c = null;
    } else {
      _c ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 36),
      )..repeat();
    }
    _nested = nested;
  }

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
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _c;
    // An ancestor already paints it — anything we drew here would be hidden
    // behind our own opaque fill anyway.
    if (_nested || controller == null) return widget.child;

    return _EmberBackgroundScope(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
              decoration: BoxDecoration(color: MilesColors.night),),
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => CustomPaint(
                painter: _EmberPainter(
                    t: controller.value, embers: _embers, stars: _stars,),
                size: Size.infinite,
              ),
            ),
          ),
          widget.child,
        ],
      ),
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
  final double x;
  final double y0;
  final double speed;
  final double size;
  final double sway;
  final double phase;
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
  final double x;
  final double y;
  final double size;
  final double base;
  final double speed;
  final double phase;
  final bool violet;
}

class _EmberPainter extends CustomPainter {
  _EmberPainter({required this.t, required this.embers, required this.stars});
  final double t;
  final List<_Ember> embers;
  final List<_Star> stars;

  // Reused across every frame and every mounted instance. Painting is
  // synchronous on one thread, so mutating these in place is safe — and it
  // drops ~49 Paint allocations per frame per instance to zero.
  static final Paint _glowPaint = Paint();
  static final Paint _starPaint = Paint();
  static final Paint _emberPaint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);

    // Candle glow.
    final center = Offset(w * (0.5 + 0.03 * math.sin(t * 2 * math.pi)),
        h * (0.32 + 0.02 * math.cos(t * 2 * math.pi)),);
    canvas.drawRect(
      rect,
      _glowPaint
        ..shader = const RadialGradient(
          colors: [Color(0xFF3A1622), Color(0xFF1C0A10), MilesColors.nightDeep],
          stops: [0.0, 0.55, 1.0],
        ).createShader(
            Rect.fromCircle(center: center, radius: h * (0.95 + 0.08 * pulse)),),
    );

    // Stars.
    for (final s in stars) {
      final tw = 0.45 +
          0.55 * math.sin((t * s.speed + s.phase) * 2 * math.pi);
      canvas.drawCircle(
        Offset(w * s.x, h * s.y),
        s.size,
        _starPaint
          ..color = (s.violet ? MilesColors.star : MilesColors.starlight)
              .withValues(alpha: (s.base * tw).clamp(0.0, 1.0)),
      );
    }

    // Embers drifting up.
    for (final e in embers) {
      final prog = (e.y0 + 1 - (t * e.speed) % 1) % 1; // 1 → 0 upward
      final y = h * prog;
      final x = w * (e.x + e.sway * math.sin((t * 4 + e.phase) * 2 * math.pi));
      final fade = math.sin(prog * math.pi).clamp(0.0, 1.0); // dim at top/bottom
      _emberPaint.color = MilesColors.emberSoft.withValues(alpha: 0.5 * fade);
      canvas.drawCircle(Offset(x, y), e.size, _emberPaint);
    }
  }

  @override
  bool shouldRepaint(_EmberPainter old) => old.t != t;
}
