import 'package:flutter/material.dart';
import 'package:miles/core/data/media_urls.dart';
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

  /// [url] must be something an HTTP GET can actually fetch — a signed URL.
  /// Use [openStored] for anything read straight out of a table.
  static void open(BuildContext context, String url,
      {Object? heroTag, String senderName = 'a message',}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          MediaViewer(imageUrl: url, heroTag: heroTag, senderName: senderName),
    ),);
  }

  /// Opens a value held in a database column: a storage path, or a legacy
  /// `/object/public/...` URL from before the bucket closed.
  ///
  /// Neither shape is fetchable now that couple_media is private, and handing
  /// one to [open] is what put a broken-image icon on a black screen when the
  /// home check-in snap was tapped — the card beside it rendered fine, because
  /// SignedImage signs and the tap handler did not. Signing here keeps the
  /// two halves of the same tile reading the same column the same way.
  ///
  /// A value that will not sign opens nothing, matching the chat bubbles: no
  /// URL, no viewer, rather than a black screen that says nothing went wrong.
  static Future<void> openStored(BuildContext context, String bucket,
      String value,
      {Object? heroTag, String senderName = 'a message',}) async {
    final url = await MediaUrls.sign(bucket, MediaUrls.toPath(bucket, value));
    if (url == null || !context.mounted) return;
    open(context, url, heroTag: heroTag, senderName: senderName);
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
