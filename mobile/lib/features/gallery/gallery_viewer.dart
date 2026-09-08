import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/features/chat/widgets/video_surface.dart';
import 'package:miles/features/gallery/gallery_repository.dart';

/// Full-screen pager for the shared gallery.
///
/// Mechanics lifted from `features/chat/widgets/media_viewer.dart`, which is
/// the one surface in this app that already swipes well:
///
/// * `allowImplicitScrolling` builds exactly ±1, so a swipe lands on a page
///   that has already decoded.
/// * The THUMBNAIL is an underlay LAYER, not a placeholder. As a placeholder it
///   is unmounted the instant the original resolves — or errors — so a slow
///   network showed black where a soft-but-correct picture was available.
/// * Physics are removed while zoomed rather than raced: Scrollable claims the
///   pointer at kTouchSlop (18px) and InteractiveViewer's scale recogniser only
///   at kPanSlop (36px), so a one-finger pan inside a zoomed photo turns the
///   page essentially every time.
class GalleryViewer extends StatefulWidget {
  const GalleryViewer({
    required this.items,
    required this.initialIndex,
    super.key,
  });

  final List<GalleryItem> items;
  final int initialIndex;

  @override
  State<GalleryViewer> createState() => _GalleryViewerState();
}

class _GalleryViewerState extends State<GalleryViewer> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _zoomed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPage(int i) {
    // Zoom belongs to the page you left; carrying it forward would leave the
    // pager unswipeable on a video, which has no zoom to release it.
    setState(() {
      _index = i;
      _zoomed = false;
    });
    // Sign ahead of the swipe, not on arrival.
    unawaited(GalleryRepository.warmOriginals(widget.items, i));
  }

  /// Copies the picture being looked at into the owner's Private Vault.
  ///
  /// The shared gallery is the couple's — both of them see it, either of them
  /// can ask for it to be deleted, and the refusal cap means a picture can be
  /// argued away. A vault copy is the one place a keeper is only yours, and
  /// this screen was the only media surface in the app with no way to make
  /// one: chat bubbles, the chat pager and Touch all carry this button.
  ///
  /// Both branches are SaveMediaService's existing ones — the gallery lives in
  /// couple_intimate, which is exactly the bucket saveIntimatePhotoToVault and
  /// saveVideoToVault already sign against.
  Future<bool> _save() {
    final item = widget.items[_index];
    return item.isVideo
        ? SaveMediaService.saveVideoToVault(
            path: item.storagePath, senderName: 'your shared gallery',)
        : SaveMediaService.saveIntimatePhotoToVault(
            path: item.storagePath, senderName: 'your shared gallery',);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              onPageChanged: _onPage,
              allowImplicitScrolling: true,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: widget.items.length,
              itemBuilder: (_, i) => widget.items[i].isVideo
                  // Only the page being looked at gets a player. PageView
                  // builds ±1, and initialising a decoder for a video nobody
                  // has swiped to yet is three players competing for the same
                  // hardware codec — which on these handsets is how a video
                  // ends up taking "too much time to watch".
                  ? _VideoPage(item: widget.items[i], active: i == _index)
                  : _Page(
                      item: widget.items[i],
                      onZoomChanged: (z) {
                        if (z != _zoomed) setState(() => _zoomed = z);
                      },
                    ),
            ),
            Positioned(
              top: 8,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Color(0xCCFBF8F4)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_index + 1} / ${widget.items.length}',
                    style:
                        const TextStyle(color: Color(0x99FBF8F4), fontSize: 12),
                  ),
                  // Padded rather than wrapped in an IconButton: the button
                  // carries its own tap target, busy state and snackbar, and a
                  // disabled IconButton around it is a second, dead one.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: SaveMediaButton(
                      size: 24,
                      color: const Color(0xCCFBF8F4),
                      onSave: _save,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One video page: the poster instantly, the player over it.
///
/// The poster is the SAME cached thumbnail object the grid painted, so it is
/// already decoded and on disk — the frame appears immediately instead of the
/// black rectangle a cold player shows while it opens the stream. The player
/// streams from the signed URL rather than downloading first, which is only
/// possible because these objects are stored in the clear: ciphertext cannot be
/// range-requested, so the old encrypted vault had to pull the whole file
/// before a single frame could play.
class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.item, required this.active});

  final GalleryItem item;
  final bool active;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  String? _resolved;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _VideoPage old) {
    super.didUpdateWidget(old);
    if (widget.active && _resolved == null) _resolve();
  }

  /// The signed URL, synchronously if it is already warm and asynchronously if
  /// it is not.
  ///
  /// The grid fires its signing un-awaited and pushes the pager immediately, so
  /// a video can easily mount before its URL exists. Reading the cache and
  /// stopping there left the player unmounted with nothing to retry it — a
  /// video that never starts, which is indistinguishable from a slow one.
  Future<void> _resolve() async {
    final warm = MediaUrls.cached(privateBucket, widget.item.storagePath);
    if (warm != null) {
      _resolved = warm;
      return;
    }
    final url = await MediaUrls.sign(privateBucket, widget.item.storagePath);
    if (mounted) setState(() => _resolved = url);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final active = widget.active;
    final posterUrl = MediaUrls.cached(privateBucket, item.gridPath);
    final videoUrl = _resolved;

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (posterUrl != null)
          NetImage(
            posterUrl,
            cacheKey: '$privateBucket/${item.gridPath}',
            thumb: true,
            fit: BoxFit.contain,
          ),
        if (active && videoUrl != null)
          // Keyed by path so swiping from one video to the next builds a fresh
          // surface rather than handing the old controller a different URL.
          VideoSurface(url: videoUrl, key: ValueKey(item.storagePath))
        else if (!active && posterUrl != null)
          const Center(
            child: Icon(Icons.play_circle_fill,
                size: 56, color: Color(0xCCFBF8F4),),
          ),
      ],
    );
  }
}

class _Page extends StatefulWidget {
  const _Page({required this.item, required this.onZoomChanged});

  final GalleryItem item;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final TransformationController _transform = TransformationController();

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    _transform
      ..removeListener(_onTransform)
      ..dispose();
    super.dispose();
  }

  void _onTransform() =>
      widget.onZoomChanged(_transform.value.getMaxScaleOnAxis() > 1.01);

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final thumbUrl = MediaUrls.cached(privateBucket, item.gridPath);
    final fullUrl = MediaUrls.cached(privateBucket, item.storagePath);
    final viewportPx = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context))
        .round();

    return InteractiveViewer(
      transformationController: _transform,
      maxScale: 5,
      child: Center(
        child: Hero(
          tag: 'gallery-${item.id}',
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (thumbUrl != null)
                NetImage(
                  thumbUrl,
                  cacheKey: '$privateBucket/${item.gridPath}',
                  // Unbounded and the same key the grid used, so this is the
                  // frame the grid already decoded — it paints with no work.
                  thumb: true,
                  fit: BoxFit.contain,
                ),
              if (fullUrl != null)
                NetImage(
                  fullUrl,
                  cacheKey: '$privateBucket/${item.storagePath}',
                  // Bounded at the viewport: a 12-megapixel original decoded at
                  // source resolution is ~48MB of raster for a screen that
                  // shows a fraction of it. Full quality is preserved on disk
                  // and on the wire — this bounds the DECODE, not the file.
                  decodeWidth: viewportPx,
                  fit: BoxFit.contain,
                  // Drawn over the thumbnail rather than replacing it, so a
                  // failure leaves the soft copy visible instead of black.
                  error: const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
