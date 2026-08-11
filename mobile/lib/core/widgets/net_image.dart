import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    // Decode at display size, not source size. `width`/`height` are layout-only
    // — without these a 2400px upload is decoded at full resolution into a 40px
    // avatar, which is what fills the image cache and forces re-decodes on the
    // raster thread while scrolling. Only hinted when the caller gave a bound.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = width;
    final h = height;
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: cacheKey,
      fit: fit,
      width: w,
      height: h,
      memCacheWidth: (w != null && w.isFinite) ? (w * dpr).round() : null,
      memCacheHeight: (h != null && h.isFinite) ? (h * dpr).round() : null,
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => const ColoredBox(color: MilesColors.surface2),
      errorWidget: (_, __, ___) =>
          error ?? const ColoredBox(color: MilesColors.surface2),
    );
  }
}
