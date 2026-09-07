import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/features/chat/camera/camera_filters.dart';

/// Wraps the live camera preview ([child]) in the selected filter's visual
/// stack — colour matrix, optional blur, optional blended overlay, optional
/// animated film grain. Purely visual; the real pixels are only transformed at
/// capture time (camera_bake.dart), so this costs nothing but a few shader ops.
class FilterPreviewLayer extends StatelessWidget {
  const FilterPreviewLayer({
    required this.filter, required this.child, super.key,
  });

  final CameraFilter filter;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 1. colour matrix
    Widget layer = ColorFiltered(
      colorFilter: ColorFilter.matrix(filter.colorMatrix),
      child: child,
    );

    // 2. blur (e.g. Soft)
    if (filter.blurSigma > 0) {
      layer = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: filter.blurSigma,
          sigmaY: filter.blurSigma,
        ),
        child: layer,
      );
    }

    // 3. blended colour overlay (e.g. Neon screen, Glitch overlay)
    final overlay = filter.overlayColor;
    if (overlay != null) {
      layer = Stack(
        fit: StackFit.expand,
        children: [
          layer,
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                backgroundBlendMode: filter.overlayBlendMode,
                color: overlay,
              ),
            ),
          ),
        ],
      );
    }

    // 4. animated film grain (e.g. Freesia, Retro)
    if (filter.hasGrain) {
      layer = Stack(
        fit: StackFit.expand,
        children: [
          layer,
          IgnorePointer(child: _GrainOverlay(intensity: filter.grainIntensity)),
        ],
      );
    }

    return layer;
  }
}

/// A film-grain layer that re-seeds at ~15fps (deliberately NOT vsync/60fps —
/// fast grain reads as TV static; ~15fps reads as film). Isolated in a
/// [RepaintBoundary] so only the grain repaints, never the camera preview.
class _GrainOverlay extends StatefulWidget {
  const _GrainOverlay({required this.intensity});

  final double intensity;

  @override
  State<_GrainOverlay> createState() => _GrainOverlayState();
}

class _GrainOverlayState extends State<_GrainOverlay> {
  Timer? _timer;
  int _seed = 0;

  /// One small noise bitmap, built once and repeated across the surface by a
  /// shader.
  ///
  /// The old painter walked the whole preview in 2x2 cells and issued a
  /// `drawRect` per cell — on a 411x914 logical surface that is 206 x 457 =
  /// 94,142 draw calls, re-run 15 times a second, with `shouldRepaint` always
  /// true. One tiled shader is one draw call for the same look, and the grain
  /// still moves because [_seed] shifts the shader's origin each frame instead
  /// of recolouring 94,142 rectangles.
  ui.Image? _tile;

  static const int _tilePx = 64;

  @override
  void initState() {
    super.initState();
    unawaited(_buildTile());
    _timer = Timer.periodic(const Duration(milliseconds: 66), (_) {
      if (!mounted) return;
      setState(() => _seed = DateTime.now().millisecondsSinceEpoch % 100000);
    });
  }

  Future<void> _buildTile() async {
    const n = _tilePx;
    final pixels = Uint8List(n * n * 4);
    // Deterministic: the tile is the grain's texture, not its animation. The
    // movement comes from the per-frame shader offset below.
    var state = 0x9E3779B9;
    for (var i = 0; i < n * n; i++) {
      state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
      final v = (state >> 16) & 0xFF;
      pixels[i * 4] = v;
      pixels[i * 4 + 1] = v;
      pixels[i * 4 + 2] = v;
      pixels[i * 4 + 3] = 0xFF;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: n,
      height: n,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() => _tile = frame.image);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tile?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tile = _tile;
    // Nothing to draw until the tile exists — a frame or two after open, and
    // grain is the last thing anyone would notice missing.
    if (tile == null) return const SizedBox.shrink();
    return RepaintBoundary(
      // The Opacity wrapper is gone: it forced a saveLayer over the whole
      // preview every grain frame, on top of the overlay blend. The same
      // intensity-squared result now rides the paint's own alpha, which costs
      // nothing.
      child: CustomPaint(
        size: Size.infinite,
        painter: _GrainPainter(
          seed: _seed,
          intensity: widget.intensity,
          tile: tile,
        ),
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  _GrainPainter({
    required this.seed,
    required this.intensity,
    required this.tile,
  });

  final int seed;
  final double intensity;
  final ui.Image tile;

  /// Logical pixels per grain cell — the tile is drawn at 2x its pixel size so
  /// a cell stays the 2x2 block the original painter used.
  static const double _block = 2;

  @override
  void paint(Canvas canvas, Size size) {
    // Intensity applied ONCE, squared, exactly as before: the old tree wrapped
    // this painter in Opacity(intensity) AND set alpha to intensity*80, so the
    // effective alpha has always been intensity^2 * 80. Folding it here removes
    // the saveLayer without changing a pixel of the result.
    final alpha = (intensity * intensity * 80).round().clamp(0, 255);
    // The seed slides the tile origin, which is what makes the grain crawl.
    // Two different primes so it does not travel on a diagonal.
    final ox = (seed * 7 % _tileSpan).toDouble();
    final oy = (seed * 13 % _tileSpan).toDouble();
    final matrix = Matrix4.identity()
      ..translate(-ox, -oy)
      ..scale(_block, _block);
    final paint = Paint()
      ..blendMode = BlendMode.overlay
      ..color = Color.fromARGB(alpha, 255, 255, 255)
      ..shader = ui.ImageShader(
        tile,
        TileMode.repeated,
        TileMode.repeated,
        matrix.storage,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  /// The tile's period in logical pixels, so an offset wraps cleanly.
  static const int _tileSpan = 64 * 2;

  @override
  bool shouldRepaint(_GrainPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.intensity != intensity ||
      oldDelegate.tile != tile;
}
