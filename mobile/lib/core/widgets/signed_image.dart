import 'package:flutter/material.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/net_image.dart';

/// An image in a PRIVATE bucket, rendered from whatever the database happens to
/// hold for it.
///
/// The stored value is a storage path now, but rows written while couple_media
/// was public hold a full `/object/public/...` URL instead. Those stop
/// resolving the moment the bucket closes, so both shapes go through
/// [MediaUrls.toPath] and come out signed.
///
/// Used for the few single images — avatar, check-in snap — that are not part
/// of a page the repository can warm in one round trip. Chat media does not use
/// this: signing per bubble would put a request behind every photo in the
/// conversation.
class SignedImage extends StatefulWidget {
  const SignedImage({
    required this.bucket,
    required this.value,
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.thumb = false,
    this.decodeWidth,
  });

  final String bucket;

  /// A storage path, or a legacy public URL.
  final String? value;

  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;

  /// See [NetImage.thumb] and [NetImage.decodeWidth]. Passed straight through:
  /// this widget only resolves the URL, it does not decide the decode.
  final bool thumb;
  final int? decodeWidth;

  @override
  State<SignedImage> createState() => _SignedImageState();
}

class _SignedImageState extends State<SignedImage> {
  String? _url;
  String? _path;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(SignedImage old) {
    super.didUpdateWidget(old);
    // A new avatar replaces the old one in place; without this the widget keeps
    // showing whatever it signed the first time it was built.
    if (old.value != widget.value || old.bucket != widget.bucket) _resolve();
  }

  Future<void> _resolve() async {
    final v = widget.value;
    if (v == null || v.isEmpty) {
      if (mounted) setState(() => _url = null);
      return;
    }
    final path = MediaUrls.toPath(widget.bucket, v);
    _path = path;
    final cached = MediaUrls.cached(widget.bucket, path);
    if (cached != null) {
      if (mounted) setState(() => _url = cached);
      return;
    }
    final signed = await MediaUrls.sign(widget.bucket, path);
    if (mounted) setState(() => _url = signed);
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null) {
      return widget.placeholder ??
          SizedBox(
            width: widget.width,
            height: widget.height,
            child: const ColoredBox(color: MilesColors.surface2),
          );
    }
    // Keyed by the path this signed, not by the URL it signed to. The token in
    // that URL rotates every 24h, so a URL-keyed cache re-downloads the whole
    // library the next day and fills the disk with copies of bytes it has.
    return NetImage(url,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        thumb: widget.thumb,
        decodeWidth: widget.decodeWidth,
        cacheKey: '${widget.bucket}/$_path',);
  }
}
