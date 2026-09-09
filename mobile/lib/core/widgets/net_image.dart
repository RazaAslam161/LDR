import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:miles/core/media/plain_media_cache.dart';
import 'package:miles/core/ui/theme.dart';

/// A disk-cached network image for avatars / photos so they don't re-download
/// every render or on app restart. (Use plain Image.network for GIFs, which
/// some cache configs don't animate.)
class NetImage extends StatelessWidget {
  const NetImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.error,
    this.cacheKey,
    this.thumb = false,
    this.decodeWidth,
    this.placeholder,
    this.fadeIn,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? error;

  /// What to file these bytes under, when [url] is a signed URL.
  ///
  /// Without it the cache is keyed by a URL with an expiring token in it, so
  /// every image in the app re-downloads the day after it was first seen and
  /// the disk fills with copies of bytes it already has. Pass
  /// `'<bucket>/<path>'` — the path is stable, the URL is not.
  final String? cacheKey;

  /// True when [url] points at a thumbnail — an object already small enough
  /// that bounding its decode buys nothing.
  ///
  /// It costs something, though, so this is not merely an optimisation.
  /// memCacheWidth becomes part of the ResizeImage key, so the same thumbnail
  /// requested at five slightly different box sizes is five decodes of one
  /// file. Left unbounded, the chat bubble, the album tile, the profile tile
  /// and the viewer's placeholder all share a single decoded image.
  final bool thumb;

  /// The exact pixel width to decode at, overriding the layout-derived one.
  ///
  /// Pass a SHARED constant (see media_decode.dart) wherever two surfaces paint
  /// the same object. Flutter keys a decoded frame on the provider and its
  /// resize bounds together, so a grid tile at 360px and a viewer underlay at
  /// 412px are two decodes of one file — the hand-off that is supposed to make
  /// opening a photo instant silently does not happen.
  final int? decodeWidth;

  /// What to paint while the bytes are being read, INSTEAD of the default
  /// opaque block.
  ///
  /// The default is right for a tile with nothing behind it — a grid cell that
  /// paints nothing reads as a hole. It is wrong, and badly so, for a layer
  /// stacked over another picture: `MilesColors.surface2` is fully opaque, so
  /// a viewer that draws its original over an already-decoded thumbnail was
  /// covering that thumbnail with a maroon rectangle for the length of a disk
  /// read and a decode, and then cross-fading out of it. That block is what a
  /// swipe looks like when the photograph underneath was ready the whole time.
  /// Pass `SizedBox.shrink()` from any layered call site.
  final Widget? placeholder;

  /// Overrides the 150ms cross-fade.
  ///
  /// Zero belongs anywhere something correct is already on screen: fading in
  /// over a good thumbnail is 150ms of two images composited to arrive at the
  /// picture that was there at the start.
  final Duration? fadeIn;

  @override
  Widget build(BuildContext context) {
    // Decode at display size, not source size. `width`/`height` are layout-only
    // — without these a 2400px upload is decoded at full resolution into a 40px
    // avatar, which is what fills the image cache and forces re-decodes on the
    // raster thread while scrolling. Only hinted when the caller gave a bound.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // An explicit width wins; then the thumb rule; then the layout bound.
    final decodePx = decodeWidth ??
        (thumb
            ? null
            : (width != null && width!.isFinite)
                ? (width! * dpr).round()
                : null);
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: cacheKey,
      // Not DefaultCacheManager. Its 200 objects are shared with every other
      // CachedNetworkImage in the app, so a couple's own gallery evicts itself
      // by being scrolled and every later visit re-downloads it.
      cacheManager: PlainMediaCache.manager,
      fit: fit,
      width: width,
      height: height,
      memCacheWidth: decodePx,
      // memCacheHeight is deliberately never set. It joins the resize key, so
      // a square tile passing both dimensions cannot share a decode with any
      // surface that passes width alone — which is every other surface.
      fadeInDuration: fadeIn ?? const Duration(milliseconds: 150),
      // The default is 1000ms of cross-fading the OLD image out. On a grid
      // that recycles cells while scrolling that is a second of two frames
      // composited per cell, for no visual gain.
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) =>
          placeholder ?? const ColoredBox(color: MilesColors.surface2),
      errorWidget: (_, __, ___) =>
          error ?? const ColoredBox(color: MilesColors.surface2),
    );
  }
}
