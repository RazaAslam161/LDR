import 'package:flutter/material.dart';

/// Full-screen image viewer with pinch-zoom + pan. Used for chat photos and the
/// home snap. Tap the backdrop or the X to close.
class MediaViewer extends StatelessWidget {
  const MediaViewer({super.key, required this.imageUrl, this.heroTag});

  final String imageUrl;
  final Object? heroTag;

  static void open(BuildContext context, String url, {Object? heroTag}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(imageUrl: url, heroTag: heroTag),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final image = Image.network(
      imageUrl,
      fit: BoxFit.contain,
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : const Center(
              child: CircularProgressIndicator(color: Colors.white70)),
      errorBuilder: (_, __, ___) => const Center(
        child:
            Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 5,
                child: Center(
                  child: heroTag != null
                      ? Hero(tag: heroTag!, child: image)
                      : image,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
