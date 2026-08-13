import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/media_source.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/core/widgets/signed_image.dart';
import 'package:miles/features/chat/widgets/video_surface.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/core/media/media_decode.dart';

/// Full-screen media, paged.
///
/// The screen this replaces opened one item and closed. Opening the third
/// photo of five thousand and not being able to reach the fourth without
/// closing and re-opening the grid is the whole reason this exists, so paging
/// is not a feature of this widget — it is the widget.
///
/// It pages a [MediaSource], never a copied list, so the window the grid is
/// showing and the window the pager is swiping through are one object: swipe
/// past what the grid had loaded and the grid has it too when you come back.
class MediaViewer extends StatefulWidget {
  const MediaViewer({
    required this.source,
    this.initialIndex = 0,
    super.key,
  });

  final MediaSource source;
  final int initialIndex;

  static Future<void> open(BuildContext context, MediaSource source,
      {int index = 0,}) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => MediaViewer(source: source, initialIndex: index),
    ),);
  }

  /// Opens a single value held in a database column: a storage path, or a
  /// legacy `/object/public/...` URL from before the buckets closed.
  ///
  /// Neither shape is fetchable now that they are private, and handing one
  /// straight to an Image.network is what put a broken-image icon on a black
  /// screen when the home check-in snap was tapped. Nothing here signs up
  /// front any more — the page does it, and can do it again when a token dies
  /// under it.
  static Future<void> openStored(
    BuildContext context,
    String bucket,
    String value, {
    Object? heroTag,
    String senderName = 'a message',
    bool isVideo = false,
  }) {
    return open(
      context,
      SingleMediaSource(MediaItem.stored(bucket, value,
          isVideo: isVideo, senderName: senderName, heroTag: heroTag,)),
    );
  }

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer>
    with SingleTickerProviderStateMixin {
  static const _maxScale = 5.0;
  static const _doubleTapScale = 2.5;

  /// Below this a matrix is identity as far as anyone can tell, and floating
  /// point never gets back to exactly 1.0 after a pinch.
  static const _zoomEpsilon = 1.01;

  /// Pages either side whose FILE is warmed. Not the image: ±1 is already
  /// built by allowImplicitScrolling and resolves its own provider, and
  /// forcing a decode out here would put three 12MP bitmaps — around 48MB each
  /// — into a 100MiB image cache and evict the page being looked at.
  static const _warmRadius = 3;

  /// Ask for another page this far from the end of the loaded window. Thirty
  /// rows arrive per page and nobody swipes five pages in a round trip, so the
  /// end is never reached with a spinner on it.
  static const _extendWithin = 5;

  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  final TransformationController _transform = TransformationController();
  late final AnimationController _zoom = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220),);
  Animation<Matrix4>? _zoomTo;

  late int _index = widget.initialIndex;
  bool _chrome = true;
  bool _zoomed = false;
  bool _settled = true;
  bool _warming = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    _zoom.addListener(_onZoomTick);
    widget.source.addListener(_onSourceChanged);
    _applySecure(_index);
    _maybeExtend(_index);
    unawaited(_warm());
  }

  @override
  void dispose() {
    widget.source.removeListener(_onSourceChanged);
    _transform.removeListener(_onTransform);
    _zoom
      ..removeListener(_onZoomTick)
      ..dispose();
    _transform.dispose();
    _pages.dispose();
    unawaited(SecureScreen.clearSecure());
    super.dispose();
  }

  /// The pager's own drag and the zoom gesture are not arbitrated by the
  /// gesture arena here, because the arena decides it the wrong way every
  /// time: Scrollable's horizontal drag claims the pointer at kTouchSlop
  /// (18px) while InteractiveViewer's scale recogniser only claims it at
  /// kPanSlop (36px), so a single-finger pan inside a zoomed photo is a page
  /// turn 100% of the time. Rather than race it, the competitor is removed —
  /// zoomed in, the pager has no physics to drag with at all.
  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > _zoomEpsilon;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onZoomTick() {
    final to = _zoomTo;
    if (to != null) _transform.value = to.value;
  }

  /// The window grew under us — more pages to swipe into, and the grid behind
  /// has them too.
  void _onSourceChanged() {
    if (mounted) setState(() {});
  }

  void _onPageChanged(int i) {
    // Landing on the next photo already at 3× on some corner of it is the
    // tell of a hand-rolled viewer. Reset before the page is interactive; this
    // also drops _zoomed, which hands the physics back to the pager.
    _zoom.stop();
    _zoomTo = null;
    _transform.value = Matrix4.identity();
    setState(() => _index = i);
    _applySecure(i);
    _maybeExtend(i);
    unawaited(_warm());
  }

  /// A photo lives in couple_media and a video in couple_intimate, and the
  /// player this replaced carried FLAG_SECURE for exactly that reason. In a
  /// mixed pager the flag has to follow the page rather than the screen.
  void _applySecure(int i) {
    if (i >= widget.source.length) return;
    unawaited(widget.source.itemAt(i).isVideo
        ? SecureScreen.setSecure()
        : SecureScreen.clearSecure(),);
  }

  void _maybeExtend(int i) {
    if (i >= widget.source.length - _extendWithin) widget.source.extend();
  }

  /// Put the neighbours on disk AND, for the immediate ones, through the
  /// decoder — so arriving on a page is a paint rather than a download or a
  /// decode.
  ///
  /// The old version stopped at the file. "Arriving on the page is a decode
  /// rather than a download" was true and was still the wrong finish line: a
  /// 12MP decode is ~100ms of CPU that lands on the raster thread in the middle
  /// of the swipe animation, which is a stutter and then a spinner. The bytes
  /// were the cheap half.
  ///
  /// Distance 1 is decoded, 2 and 3 are only fetched. Decoding the whole radius
  /// would hold four full-size images resident to save a decode the user may
  /// never ask for.
  Future<void> _warm() async {
    // One loop, however fast the swiping is. Ten pages in a second would
    // otherwise start ten of these, each holding four downloads open, and a
    // phone uplink spends the whole burst fetching photographs that were
    // already three swipes behind by the time they arrived.
    if (_warming) return;
    _warming = true;
    try {
      // The immediate neighbours, decoded. precacheImage puts the frame in
      // Flutter's ImageCache under the same provider CachedNetworkImage will
      // construct, so the page finds it already resident.
      for (final direction in const [1, -1]) {
        final i = _index + direction;
        if (i < 0 || i >= widget.source.length) continue;
        final item = widget.source.itemAt(i);
        if (item.isVideo) continue;
        final url = await MediaUrls.sign(item.bucket, item.path);
        if (!mounted) return;
        if (url == null) continue;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final w = (MediaQuery.sizeOf(context).width * dpr).round();
        try {
          await precacheImage(
            ResizeImage(
              CachedNetworkImageProvider(url, cacheKey: item.cacheKey),
              width: w,
            ),
            context,
          );
        } catch (_) {
          // A miss costs one spinner on one page. Never worth failing a swipe.
        }
        if (!mounted) return;
      }
      for (var d = 2; d <= _warmRadius; d++) {
        for (final direction in const [1, -1]) {
          // Re-read rather than captured: a swipe during the await above moved
          // what "two pages out" means, and the loop should follow it.
          final i = _index + d * direction;
          if (i < 0 || i >= widget.source.length) continue;
          final item = widget.source.itemAt(i);
          // Video streams and is measured in tens of megabytes. Pre-fetching
          // one nobody has asked for is the opposite of this optimisation.
          if (item.isVideo) continue;
          final url = await MediaUrls.sign(item.bucket, item.path);
          if (!mounted) return;
          if (url == null) continue;
          try {
            await DefaultCacheManager().getSingleFile(url, key: item.cacheKey);
          } catch (_) {
            // A warm that misses costs a spinner when the page arrives. It is
            // never worth surfacing and never worth failing the swipe for.
          }
          if (!mounted) return;
        }
      }
    } finally {
      _warming = false;
    }
  }

  void _doubleTapAt(Offset point) {
    final zoomedIn = _transform.value.getMaxScaleOnAxis() > _zoomEpsilon;
    // Anchored on what was tapped. Double-tapping a face and being zoomed to
    // the middle of the photograph instead is the thing this avoids.
    final target = zoomedIn
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..translateByDouble(-point.dx * (_doubleTapScale - 1),
              -point.dy * (_doubleTapScale - 1), 0, 1,)
          ..scaleByDouble(
              _doubleTapScale, _doubleTapScale, _doubleTapScale, 1,));
    _zoomTo = Matrix4Tween(begin: _transform.value, end: target).animate(
      CurvedAnimation(parent: _zoom, curve: Curves.easeOutCubic),
    );
    _zoom.forward(from: 0);
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollEndNotification) {
      if (!_settled) setState(() => _settled = true);
      return false;
    }
    if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
      final page = _pages.hasClients ? _pages.page : null;
      if (_settled && page != null && (page - _index).abs() > 0.02) {
        setState(() => _settled = false);
      }
    }
    return false;
  }

  Future<bool> _save(MediaItem item) async {
    if (item.isVideo) {
      return SaveMediaService.saveVideoToVault(
          path: item.path, senderName: item.senderName,);
    }
    final url = await MediaUrls.sign(item.bucket, item.path);
    if (url == null) return false;
    return SaveMediaService.savePhotoToVault(
        url: url, senderName: item.senderName,);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.source.length;
    if (count == 0) {
      return const Scaffold(backgroundColor: Colors.black, body: SizedBox());
    }
    final index = _index.clamp(0, count - 1);
    final current = widget.source.itemAt(index);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: PageView.builder(
                controller: _pages,
                // Exactly one page either side is built and everything else is
                // torn down, so the fiftieth swipe costs what the first did.
                // Without it there is no preload at all and every swipe is a
                // cold start; with a wider cache extent the process dies on a
                // 2GB handset somewhere in the second hundred.
                allowImplicitScrolling: true,
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                onPageChanged: _onPageChanged,
                itemCount: count,
                itemBuilder: (_, i) => _buildPage(i, index),
              ),
            ),
          ),
          Positioned.fill(
            child: _Chrome(
              visible: _chrome,
              item: current,
              source: widget.source,
              position: index,
              total: count,
              onSave: () => _save(current),
              onJump: _jumpTo,
            ),
          ),
        ],
      ),
    );
  }

  /// Jump straight to a thumbnail the user tapped in the strip.
  ///
  /// Not animateToPage: across four hundred items that scrolls the whole set
  /// past the viewport, building and tearing down every page on the way.
  void _jumpTo(int i) {
    if (i == _index || !_pages.hasClients) return;
    _pages.jumpToPage(i);
  }

  Widget _buildPage(int i, int index) {
    final item = widget.source.itemAt(i);
    if (item.isVideo) {
      // Only when it is the page being looked at AND the pager has stopped.
      // Built for its neighbours as well, a run of videos would open three
      // platform decoders and three network sessions for the one being
      // watched, and playback would carry on over the photo after it.
      return _VideoPage(item: item, active: i == index && _settled);
    }
    return _PhotoPage(
      item: item,
      // Full resolution on the page in front of you; the neighbours decode at
      // viewport size. Three full-resolution decodes alive at once is ~144MB
      // against a 100MiB budget, which evicts the one being looked at.
      full: i == index,
      transform: _transform,
      maxScale: _maxScale,
      onTap: () => setState(() => _chrome = !_chrome),
      onDoubleTapAt: _doubleTapAt,
    );
  }
}

/// One photograph: signed, zoomable, and able to recover from its own URL
/// dying underneath it.
class _PhotoPage extends StatefulWidget {
  const _PhotoPage({
    required this.item,
    required this.full,
    required this.transform,
    required this.maxScale,
    required this.onTap,
    required this.onDoubleTapAt,
  });

  final MediaItem item;
  final bool full;
  final TransformationController transform;
  final double maxScale;
  final VoidCallback onTap;
  final void Function(Offset) onDoubleTapAt;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> {
  String? _url;
  bool _resolving = true;
  bool _dead = false;
  bool _reSigned = false;
  Offset _tapPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    // Synchronously first. MediaUrls.cached is a map lookup, and the page the
    // user is arriving at was signed by _warm several swipes ago — so going
    // straight to the async path meant a guaranteed frame of spinner for a URL
    // that was already in hand. That was the first of the TWO spinners every
    // page used to show.
    final warm = MediaUrls.cached(widget.item.bucket, widget.item.path);
    if (warm != null) {
      _url = warm;
      _resolving = false;
    } else {
      unawaited(_resolve());
    }
  }

  Future<void> _resolve() async {
    final url =
        await MediaUrls.sign(widget.item.bucket, widget.item.path);
    if (!mounted) return;
    setState(() {
      _url = url;
      _resolving = false;
      _dead = url == null;
    });
  }

  /// The signed URL stopped working. This app has painted a broken-image icon
  /// for that twice; a token is re-mintable from the path, so the first
  /// failure buys a fresh one rather than an apology.
  void _onImageFailed() {
    if (_reSigned || !mounted) return;
    _reSigned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final url =
          await MediaUrls.refresh(widget.item.bucket, widget.item.path);
      if (!mounted) return;
      setState(() {
        _url = url;
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
    final url = _url;
    final Widget content;
    if (_resolving) {
      content = const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    } else if (url == null || _dead) {
      content = _Failed(onRetry: _retry);
    } else {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final width = MediaQuery.sizeOf(context).width;

      // ONE decode width for every page, current or not.
      //
      // This used to be `widget.full ? 2.0 : 1.0`, which meant the neighbour
      // Flutter had already decoded carried a different ResizeImageKey from the
      // page it was about to become — so arriving discarded the finished frame
      // and decoded the same file again, which is the stutter-then-spinner the
      // precache was added to remove. Zoom is served by a separate layer that
      // is mounted only while pinched, so no page pays 2x for a gesture most
      // pages never receive.
      final decodePx = (width * dpr).round();

      // The thumbnail as a LAYER, not a placeholder.
      //
      // As a placeholder it was unmounted the instant the full image resolved
      // OR errored — so a soft-but-correct photograph was replaced by a grey
      // failure card whenever the original failed to load. Underneath, it stays
      // until something better is painted over it, and a failure leaves the
      // thumbnail on screen with the retry drawn on top.
      //
      // Only where a real thumbnail exists: for media predating the pipeline
      // tilePath IS path, so this would be the same object twice.
      final thumbUrl = widget.item.hasThumb
          ? MediaUrls.cached(widget.item.bucket, widget.item.tilePath)
          : null;

      final image = Stack(
        fit: StackFit.expand,
        children: [
          if (thumbUrl != null)
            CachedNetworkImage(
              imageUrl: thumbUrl,
              cacheKey: widget.item.tileCacheKey,
              fit: BoxFit.contain,
              // Unbounded on purpose: a thumbnail IS its own bound, and this
              // is the exact key/bounds pair the grid tile decoded, so the
              // frame is already resident and this paints without work.
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              placeholder: (_, __) => const ColoredBox(color: Colors.black),
              errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black),
            ),
          CachedNetworkImage(
            imageUrl: url,
            cacheKey: widget.item.cacheKey,
            fit: BoxFit.contain,
            memCacheWidth: decodePx,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            // Nothing underneath means nothing to look at, so the delayed
            // indicator is allowed. With a thumbnail underneath it never is —
            // a spinner over a perfectly good photograph is the complaint.
            placeholder: (_, __) => thumbUrl != null
                ? const SizedBox.shrink()
                : const _DelayedSpinner(),
            errorWidget: (_, __, ___) {
              _onImageFailed();
              // Drawn OVER the underlay rather than replacing it — this is
              // the top of a Stack, so a thumbnail that has already painted
              // stays visible behind the retry instead of being thrown away
              // because the original 404'd.
              return _Failed(onRetry: _retry);
            },
          ),
        ],
      );
      // Unconditional Hero. Conditioned on `full`, the widget TYPE at this slot
      // changed as pages became current — Hero to no-Hero — which remounts the
      // element and restarts the decode that was already finished. Non-current
      // pages get a tag nothing can fly to, so the flight still only happens
      // for the page the user is actually on.
      content = Center(
        child: Hero(
          tag: widget.full
              ? widget.item.heroTag
              : '__offstage__${widget.item.cacheKey}',
          child: image,
        ),
      );
    }

    return GestureDetector(
      // A tap gets the caption out of the way. It must not close the viewer:
      // in a pager that throws you back to the grid and loses your place, and
      // dismissing is what Back is for.
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapPoint = d.localPosition,
      onDoubleTap: () => widget.onDoubleTapAt(_tapPoint),
      child: InteractiveViewer(
        transformationController: widget.transform,
        maxScale: widget.maxScale,
        child: SizedBox.expand(child: content),
      ),
    );
  }
}

/// One video page. A poster until it is the page being looked at.
class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.item, required this.active});

  final MediaItem item;
  final bool active;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  String? _url;
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    final url = await MediaUrls.sign(widget.item.bucket, widget.item.path);
    if (!mounted) return;
    setState(() {
      _url = url;
      _resolving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (widget.active && url != null) {
      // Keyed by the path: swiping from one video to the next must build a new
      // surface rather than hand the old controller a different URL.
      return VideoSurface(url: url, key: ValueKey(widget.item.cacheKey));
    }
    if (!_resolving && url == null) return _Failed(onRetry: _resolve);
    // Nothing in this app has ever generated a video thumbnail, and fetching a
    // 30MB file to draw one is the download this screen exists to avoid.
    return const Center(
      child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 64),
    );
  }
}

/// A progress indicator that only appears once nothing has painted for
/// [kIndicatorDelay].
///
/// Gated on time, not on state. A row whose has_thumb is true but whose
/// thumbnail object is missing signs to nothing, and without this the page is
/// pure black for the whole original download with nothing to say it is
/// working.
class _DelayedSpinner extends StatefulWidget {
  const _DelayedSpinner();

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  bool _show = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(kIndicatorDelay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _show
      ? const Center(child: CircularProgressIndicator(color: Colors.white70))
      : const ColoredBox(color: Colors.black);
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined,
              color: Colors.white54, size: 48,),
          TextButton(
            onPressed: onRetry,
            child: const Text('Try again',
                style: TextStyle(color: Colors.white),),
          ),
        ],
      ),
    );
  }
}

/// The close button, the counter, the save button and the caption.
class _Chrome extends StatelessWidget {
  const _Chrome({
    required this.visible,
    required this.item,
    required this.source,
    required this.position,
    required this.total,
    required this.onSave,
    required this.onJump,
  });

  final bool visible;
  final MediaItem item;

  /// The whole set, for the filmstrip — which needs every item, not just the
  /// one being shown.
  final MediaSource source;

  final int position;
  final int total;
  final Future<bool> Function() onSave;
  final void Function(int) onJump;

  @override
  Widget build(BuildContext context) {
    final sentAt = item.sentAt;
    final caption = sentAt == null
        ? item.senderName
        : '${item.senderName} · ${DateFormat('d MMM y').format(sentAt)}';

    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: Column(
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black, Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white, size: 28,),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        total > 1 ? '${position + 1} of $total' : '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14,),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: SaveMediaButton(
                          size: 24, color: Colors.white, onSave: onSave,),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black, Colors.transparent],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (total > 1)
                      _Filmstrip(
                        source: source,
                        index: position,
                        onJump: onJump,
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                      child: Text(
                        caption,
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The strip of thumbnails under the photo.
///
/// "3 of 412" tells you where you are and nothing about what is around you, and
/// a set that size is not something anyone swipes through one page at a time.
/// This is only affordable because tiles paint from the thumbnail objects — the
/// same bytes the grid and the chat bubble already downloaded, so scrubbing a
/// long set costs nothing new.
class _Filmstrip extends StatefulWidget {
  const _Filmstrip({
    required this.source,
    required this.index,
    required this.onJump,
  });

  final MediaSource source;
  final int index;
  final void Function(int) onJump;

  @override
  State<_Filmstrip> createState() => _FilmstripState();
}

class _FilmstripState extends State<_Filmstrip> {
  static const _thumb = 46.0;
  static const _gap = 4.0;
  static const _height = 56.0;

  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(_Filmstrip old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _centre();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keep the current thumbnail under the photo it belongs to. Without this the
  /// strip stays where it was and the marker walks off the edge of it.
  void _centre() {
    if (!_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final target = widget.index * (_thumb + _gap) - (viewport - _thumb) / 2;
    _scroll.animateTo(
      target.clamp(0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _height,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: widget.source.length,
        separatorBuilder: (_, __) => const SizedBox(width: _gap),
        itemBuilder: (_, i) {
          final item = widget.source.itemAt(i);
          final current = i == widget.index;
          return GestureDetector(
            onTap: () => widget.onJump(i),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: _thumb,
                height: current ? _thumb : _thumb - 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: current
                      ? Border.all(color: Colors.white, width: 2)
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SignedImage(
                          bucket: item.bucket,
                          value: item.tilePath,
                          width: _thumb,
                          height: _thumb,),
                      if (item.isVideo)
                        const Center(
                          child: Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 18,),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
