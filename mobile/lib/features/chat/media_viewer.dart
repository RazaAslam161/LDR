import 'package:flutter/material.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/widgets/save_media_button.dart';

/// Full-screen image viewer with pinch-zoom + pan. Used for chat photos and the
/// home snap. Tap the backdrop or the X to close.
class MediaViewer extends StatelessWidget {
  const MediaViewer({
    required this.imageUrl, super.key,
    this.heroTag,
    this.senderName = 'a message',
  });

  final String imageUrl;
  final Object? heroTag;
  final String senderName;

  static void open(BuildContext context, String url,
      {Object? heroTag, String senderName = 'a message',}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          MediaViewer(imageUrl: url, heroTag: heroTag, senderName: senderName),
    ),);
  }

  @override
  Widget build(BuildContext context) {
    final image = Image.network(
      imageUrl,
      fit: BoxFit.contain,
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : const Center(
              child: CircularProgressIndicator(color: Colors.white70),),
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
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SaveMediaButton(
                  size: 24,
                  color: Colors.white,
                  onSave: () => SaveMediaService.savePhotoToVault(
                      url: imageUrl, senderName: senderName,),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
