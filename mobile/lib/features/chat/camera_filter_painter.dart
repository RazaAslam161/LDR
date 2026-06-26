import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miles/features/chat/camera_filters.dart';

/// Wraps the live camera preview ([child]) in the selected filter's visual
/// stack — colour matrix, optional blur, optional blended overlay, optional
/// animated film grain. Purely visual; the real pixels are only transformed at
/// capture time (camera_bake.dart), so this costs nothing but a few shader ops.
class FilterPreviewLayer extends StatelessWidget {
  const FilterPreviewLayer({
    super.key,
    required this.filter,
    required this.child,
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

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 66), (_) {
      if (!mounted) return;
      setState(() => _seed = DateTime.now().millisecondsSinceEpoch % 100000);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Opacity(
        opacity: widget.intensity,
        child: CustomPaint(
          size: Size.infinite,
          painter: _GrainPainter(seed: _seed, intensity: widget.intensity),
        ),
      ),
    );
  }
}

class _GrainPainter extends CustomPainter {
  _GrainPainter({required this.seed, required this.intensity});

  final int seed;
  final double intensity;

  static const double _block = 2.0; // 2×2 logical px per grain cell

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..blendMode = BlendMode.overlay;
    final cols = (size.width / _block).ceil();
    final rows = (size.height / _block).ceil();
    final alpha = (intensity * 80).round().clamp(0, 255);
    for (var x = 0; x < cols; x++) {
      for (var y = 0; y < rows; y++) {
        final v = ((x * 1619 + y * 31337 + seed * 6301) & 0x7FFFFFFF) % 256;
        paint.color = Color.fromARGB(alpha, v, v, v);
        canvas.drawRect(
          Rect.fromLTWH(x * _block, y * _block, _block, _block),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GrainPainter oldDelegate) => true;
}
