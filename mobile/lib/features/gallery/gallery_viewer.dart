import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/media_decode.dart';
import 'package:miles/core/media/plain_media_cache.dart';
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

  /// Pages either side whose FILE is pulled down. The same radius the chat
  /// pager uses, for the same reason: three ahead outruns a fling, and a
  /// fourth is a download of a photograph nobody is going to reach.
  static const _warmRadius = 3;

  bool _warming = false;

  /// A [_warm] arrived while one was already running. Without this the last
  /// swipe of every burst is the one that never gets warmed — the loop in
  /// flight finishes around a page the user has already left, and the page
  /// they actually stopped on is the one with cold neighbours.
  bool _warmAgain = false;

  @override
  void initState() {
    super.initState();
    // The grid signed what it had on screen. This pager can be opened on any
    // item in the list, and it is THAT page's neighbours that are about to be
    // swiped into.
    unawaited(GalleryRepository.warmOriginals(widget.items, _index));
    unawaited(_warm());
  }

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
    unawaited(_warm());
  }

  /// Put the neighbours on disk AND, for the immediate ones, through the
  /// decoder.
  ///
  /// Signing ahead was all this screen ever did, and a URL is the cheap half:
  /// arriving on a page still meant downloading several megabytes and then
  /// spending ~100ms of CPU decoding them, which is the black frame between
  /// two photographs. `precacheImage` puts the frame in Flutter's ImageCache
  /// under the SAME provider [_Page] builds — `CachedNetworkImageProvider`
  /// compares on `cacheKey ?? url` and both sides pass the storage path as the
  /// key, so a token that rotates between the warm and the paint does not cost
  /// the decode.
  Future<void> _warm() async {
    if (_warming) {
      _warmAgain = true;
      return;
    }
    _warming = true;
    // Read before the first await, and ONE width for every page — the same
    // expression [_Page] decodes at. A neighbour warmed at a different width
    // carries a different ResizeImage key, so arriving would discard the
    // finished frame and decode the identical file again.
    final decodePx = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context))
        .round();
    try {
      for (var d = 1; d <= _warmRadius; d++) {
        for (final direction in const [1, -1]) {
          // Re-read rather than captured: a swipe during the awaits below
          // moved what "two pages out" means, and the loop should follow it.
          final i = _index + d * direction;
          if (i < 0 || i >= widget.items.length) continue;
          final item = widget.items[i];
          // A video streams and is measured in tens of megabytes. Pulling one
          // nobody has asked for down is the opposite of this optimisation.
          if (item.isVideo) continue;
          final url = await MediaUrls.sign(privateBucket, item.storagePath);
          if (!mounted) return;
          if (url == null) continue;
          try {
            if (d == 1) {
              await precacheImage(
                ResizeImage(
                  PlainMediaCache.provider(
                      privateBucket, item.storagePath, url,),
                  width: decodePx,
                ),
                context,
              );
            } else {
              // Bytes only past the immediate neighbours. Decoding the whole
              // radius holds six full-size bitmaps resident to save a decode
              // the user may never ask for.
              await PlainMediaCache.manager.getSingleFile(url,
                  key: PlainMediaCache.keyFor(
                      privateBucket, item.storagePath,),);
            }
          } catch (_) {
            // A warm that misses costs one spinner on one page. It is never
            // worth surfacing and never worth failing the swipe for.
          }
          if (!mounted) return;
        }
      }
    } finally {
      _warming = false;
      if (_warmAgain && mounted) {
        _warmAgain = false;
        unawaited(_warm());
      } else {
        _warmAgain = false;
      }
    }
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
            path: item.storagePath,
            senderName: 'your shared gallery',
            thumbPath: item.thumbPath,)
        : SaveMediaService.saveIntimatePhotoToVault(
            path: item.storagePath,
            senderName: 'your shared gallery',
            thumbPath: item.thumbPath,);
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
    // The poster first, and unconditionally. Read synchronously it was blank
    // whenever the grid had not already signed this row — which is every page
    // a fast swipe outruns — and a video page with no poster is a black
    // rectangle for as long as the player takes to open its stream.
    _poster ??= MediaUrls.cached(privateBucket, widget.item.gridPath);
    final warm = MediaUrls.cached(privateBucket, widget.item.storagePath);
    if (warm != null && _poster != null) {
      _resolved = warm;
      return;
    }
    final poster = _poster ??
        await MediaUrls.sign(privateBucket, widget.item.gridPath);
    final url = warm ??
        await MediaUrls.sign(privateBucket, widget.item.storagePath);
    if (mounted) {
      setState(() {
        _poster = poster;
        _resolved = url;
      });
    }
  }

  String? _poster;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final active = widget.active;
    final posterUrl = _poster;
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
            // Over the black ColoredBox, so the default maroon block is only
            // ever a flash of the wrong colour.
            placeholder: const SizedBox.shrink(),
            fadeIn: Duration.zero,
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

  String? _thumbUrl;
  String? _fullUrl;
  bool _resolving = true;
  bool _dead = false;
  bool _reSigned = false;

  /// Whether the UNBOUNDED layer is mounted over the viewport-bounded one.
  ///
  /// Without it this screen magnified a viewport-width bitmap all the way to
  /// 5x, so a photograph got softer the harder you looked at it while the
  /// original's pixels sat on disk under this exact cache key, never asked
  /// for. Two thresholds, deliberately not equal: one number mounts and
  /// unmounts a full-size decode on every jitter across the boundary.
  bool _upgraded = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    // Synchronously first, and this is why the page is not black on arrival:
    // reading the map is not a Future, and going through one costs a frame
    // with nothing painted for a URL that is already in hand.
    _thumbUrl = MediaUrls.cached(privateBucket, widget.item.gridPath);
    _fullUrl = MediaUrls.cached(privateBucket, widget.item.storagePath);
    if (_fullUrl != null) {
      _resolving = false;
    } else {
      // And this is the defect the synchronous read used to be on its own: a
      // page outside the grid's warm window read null, painted the thumbnail
      // or nothing at all, and never signed — so a fast swipe left a
      // permanently blank page carrying no error, no wheel and no way back
      // short of leaving the screen.
      unawaited(_resolve());
    }
  }

  @override
  void dispose() {
    _transform
      ..removeListener(_onTransform)
      ..dispose();
    super.dispose();
  }

  void _onTransform() {
    final scale = _transform.value.getMaxScaleOnAxis();
    widget.onZoomChanged(scale > 1.01);
    final want =
        _upgraded ? scale > kZoomRevertScale : scale > kZoomUpgradeScale;
    if (want != _upgraded && mounted) setState(() => _upgraded = want);
  }

  Future<void> _resolve() async {
    final full = await MediaUrls.sign(privateBucket, widget.item.storagePath);
    final thumb =
        _thumbUrl ?? await MediaUrls.sign(privateBucket, widget.item.gridPath);
    if (!mounted) return;
    setState(() {
      _fullUrl = full;
      _thumbUrl = thumb;
      _resolving = false;
      _dead = full == null;
    });
  }

  /// The signed URL stopped working under us. A token is re-mintable from the
  /// path, so the first failure buys a fresh one rather than an apology.
  void _onImageFailed() {
    if (_reSigned || !mounted) return;
    _reSigned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final url =
          await MediaUrls.refresh(privateBucket, widget.item.storagePath);
      if (!mounted) return;
      setState(() {
        _fullUrl = url;
        _dead = url == null;
      });
    });
  }

  void _retry() {
    setState(() {
      _resolving = true;
      _dead = false;
      _reSigned = false;
    });
    unawaited(_resolve());
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final thumbUrl = _thumbUrl;
    final fullUrl = _fullUrl;
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
                  placeholder: const SizedBox.shrink(),
                  fadeIn: Duration.zero,
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
                  // NOTHING while it reads, and no cross-fade. NetImage's
                  // default placeholder is an OPAQUE block, and this layer
                  // sits directly over the thumbnail — so the default painted
                  // maroon over a perfectly good photograph for the length of
                  // a disk read and a decode, then spent 150ms fading out of
                  // it. That block IS the blank frame on a swipe.
                  placeholder: const SizedBox.shrink(),
                  fadeIn: Duration.zero,
                  // Drawn over the thumbnail rather than replacing it, so a
                  // failure leaves the soft copy visible instead of black —
                  // and re-signs once, because a rotated token is the usual
                  // reason a picture that worked a minute ago stops.
                  error: _ReSign(onFailed: _onImageFailed),
                ),
              // The zoom layer, mounted only while pinched. Same cacheKey, so
              // nothing is fetched twice — only the decode differs, which is
              // precisely what dropping the width buys.
              if (_upgraded && fullUrl != null)
                NetImage(
                  fullUrl,
                  cacheKey: '$privateBucket/${item.storagePath}',
                  // `thumb` is the flag that means "do not bound this decode".
                  // The name is about the usual reason to want that; the
                  // effect is the one this layer exists for.
                  thumb: true,
                  fit: BoxFit.contain,
                  // Nothing while it decodes: the bounded copy is directly
                  // underneath and is a perfectly good picture. Without this
                  // the pinch this layer exists to sharpen began by covering
                  // the photograph with a grey rectangle.
                  placeholder: const SizedBox.shrink(),
                  fadeIn: Duration.zero,
                  error: const SizedBox.shrink(),
                ),
              // A wheel only where there is nothing to look at. Over a
              // thumbnail that has already painted, a spinner IS the
              // complaint rather than the fix.
              if (_resolving && thumbUrl == null)
                const _DelayedSpinner()
              else if (_dead && thumbUrl == null)
                _Failed(onRetry: _retry),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reports a dead token from the error slot of an image, once.
///
/// A widget rather than a callback at the call site because that slot is a
/// widget; the re-sign itself is deferred to a post-frame callback inside
/// [_PageState._onImageFailed], so nothing calls setState during a build.
class _ReSign extends StatelessWidget {
  const _ReSign({required this.onFailed});

  final VoidCallback onFailed;

  @override
  Widget build(BuildContext context) {
    onFailed();
    return const SizedBox.shrink();
  }
}

/// The retry card, shown only when there is no thumbnail underneath it.
class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined,
                color: Color(0x99FBF8F4), size: 40,),
            const SizedBox(height: 12),
            const Text(
              "Couldn't load this one.",
              style: TextStyle(color: Color(0x99FBF8F4), fontSize: 13),
            ),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
}

/// A wheel only once nothing has painted for [kIndicatorDelay].
///
/// Gated on "nothing is on screen yet" rather than on "we are loading": a
/// spinner that flashes for 80ms over a photograph the phone already held is
/// the exact thing this screen is being fixed for.
class _DelayedSpinner extends StatefulWidget {
  const _DelayedSpinner();

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(kIndicatorDelay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _show
      ? const Center(child: CircularProgressIndicator(color: Colors.white70))
      : const SizedBox.shrink();
}
