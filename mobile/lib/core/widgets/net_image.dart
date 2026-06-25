import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:miles/core/theme.dart';

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
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? error;

  @override
  Widget build(BuildContext context) => CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        width: width,
        height: height,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => const ColoredBox(color: MilesColors.surface2),
        errorWidget: (_, __, ___) =>
            error ?? const ColoredBox(color: MilesColors.surface2),
      );
}
