import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:miles/features/chat/theme/chat_theme.dart';

/// The themed chat gradient, dithered.
///
/// A two-stop gradient across a dark panel bands: the eye reads the steps as
/// stripes, and the cheaper the panel the wider they are. Five of the six
/// themes are dark, so five of the six band. Film has never had this problem
/// because film has grain, which is why every graded dark image carries some.
///
/// The whole-app FilmGrain motion was cut for cost — re-seeding a full screen
/// every 120ms is the work this design set out to remove, and the camera's
/// exempted grain still pays it. A grain that never moves pays none of it: one
/// tile is baked once for the process, and every frame after is a single
/// tiled rect. Nothing here animates, which is also all chat's restraint
/// budget allows.
class ChatBackdrop extends StatelessWidget {
  const ChatBackdrop({required this.theme, super.key});

  final ChatTheme theme;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _BackdropPainter(
          theme: theme,
          dpr: MediaQuery.devicePixelRatioOf(context),
        ),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter({required this.theme, required this.dpr});

  final ChatTheme theme;
  final double dpr;

  static const int _tile = 128;

  /// How many grey levels the tile carries, and how far apart they sit either
  /// side of mid-grey: 16 levels 4 apart, spanning 128±30.
  ///
  /// Overlay scales the perturbation by the base, so the finished excursion is
  /// not one number — measured across the six themes it runs 3/255 on the
  /// darkest (Starlit) to 16/255 on the lightest corner of Candlelit. That
  /// spread is the point rather than a flaw: a gradient's own steps are larger
  /// where it is brighter, so the dither has to be too. Both ends were checked
  /// by eye at dpr 1, which is the coarsest the grain can ever look — a denser
  /// panel scales it finer, never louder.
  static const int _levels = 16;
  static const double _spread = 4;

  static ui.Image? _grain;

  /// Baked once per process. Buckets rather than per-pixel draws: 16
  /// [Canvas.drawPoints] calls instead of 16,384 [Canvas.drawRect] calls.
  /// Seeded, so the tile is identical on every run and a pixel test can rely
  /// on it.
  static ui.Image _grainTile() {
    final cached = _grain;
    if (cached != null) return cached;
    final rnd = math.Random(0x5EED);
    final buckets = List.generate(_levels, (_) => <Offset>[]);
    for (var y = 0; y < _tile; y++) {
      for (var x = 0; x < _tile; x++) {
        buckets[rnd.nextInt(_levels)].add(Offset(x + 0.5, y + 0.5));
      }
    }
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final paint = Paint()..strokeWidth = 1;
    for (var i = 0; i < _levels; i++) {
      // Centred on mid-grey because the tile is composited with
      // BlendMode.overlay, which leaves 128 alone and perturbs either side of
      // it. That is what makes this dither the gradient instead of washing it
      // — a one-directional grain would lift every black in the app.
      final v = (128 + (i - (_levels - 1) / 2) * _spread).round().clamp(0, 255);
      paint.color = Color.fromARGB(255, v, v, v);
      canvas.drawPoints(ui.PointMode.points, buckets[i], paint);
    }
    return _grain = rec.endRecording().toImageSync(_tile, _tile);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          // A single-colour theme still goes through the gradient so the two
          // paths cannot drift apart; the shader collapses to a flat fill.
          colors: theme.bg.length == 1
              ? [theme.bg.first, theme.bg.first]
              : theme.bg,
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.overlay
        // One grain texel per DEVICE pixel. The shader tiles in logical space,
        // so it carries the inverse ratio — without it the grain lands in 2×2
        // and 3×3 blocks on exactly the dense panels that need it finest, and
        // reads as dirt rather than film.
        ..shader = ImageShader(
          _grainTile(),
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.diagonal3Values(1 / dpr, 1 / dpr, 1).storage,
          filterQuality: FilterQuality.none,
        ),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.dpr != dpr || !listEquals(old.theme.bg, theme.bg);
}
