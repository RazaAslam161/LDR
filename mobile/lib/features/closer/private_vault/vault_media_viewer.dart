import 'dart:io';

import 'package:flutter/material.dart';
import 'package:miles/core/media/media_decode.dart';
import 'package:miles/features/closer/private_vault/private_vault_repository.dart';
import 'package:miles/features/closer/private_vault/vault_media_cache.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:video_player/video_player.dart';

/// Full-screen, buttery smooth, swipeable media viewer for the Shared Vault.
class VaultMediaViewer extends StatefulWidget {
  const VaultMediaViewer({
    required this.items,
    required this.initialIndex,
    super.key,
  });

  final List<VaultItem> items;
  final int initialIndex;

  @override
  State<VaultMediaViewer> createState() => _VaultMediaViewerState();
}

class _VaultMediaViewerState extends State<VaultMediaViewer> {
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure();
    _pageController = PageController(initialPage: widget.initialIndex);
    _prefetchAround(widget.initialIndex);
  }

  void _prefetchAround(int index) {
    for (final neighbor in [index - 1, index + 1]) {
      if (neighbor >= 0 && neighbor < widget.items.length) {
        VaultMediaCache.prefetchOriginal(widget.items[neighbor]);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    SecureScreen.clearSecure();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: widget.items.length,
              onPageChanged: _prefetchAround,
              itemBuilder: (context, index) {
                final item = widget.items[index];
                if (item.kind == VaultKind.photo) {
                  return _PhotoPage(item: item);
                } else if (item.kind == VaultKind.video) {
                  return _VideoPage(item: item);
                } else {
                  return _NotePage(item: item);
                }
              },
            ),
            Positioned(
              top: 8,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Color(0xCCFBF8F4)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoPage extends StatefulWidget {
  const _PhotoPage({required this.item});
  final VaultItem item;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> {
  File? _file;
  String? _error;

  /// Whether the full-resolution layer is mounted over the bounded one.
  ///
  /// `kZoomUpgradeScale` and `kZoomRevertScale` have existed in
  /// `media_decode.dart` since the decode work, with a test asserting they are
  /// ordered — and **zero widget call sites**. Bounding the page decode at the
  /// viewport (which is what stops a 12-megapixel original costing ~48MB of
  /// raster) is exactly what makes them necessary: without this layer, pinching
  /// to 4x now magnifies a viewport-width bitmap instead of showing the
  /// photograph. The two thresholds differ deliberately, so jitter around the
  /// boundary does not mount and unmount a full-size decode every frame.
  bool _zoomed = false;
  final TransformationController _transform = TransformationController();

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onZoom);
    _load();
  }

  @override
  void dispose() {
    _transform
      ..removeListener(_onZoom)
      ..dispose();
    super.dispose();
  }

  void _onZoom() {
    final scale = _transform.value.getMaxScaleOnAxis();
    final want = _zoomed
        ? scale > kZoomRevertScale
        : scale > kZoomUpgradeScale;
    if (want != _zoomed && mounted) setState(() => _zoomed = want);
  }

  Future<void> _load() async {
    try {
      final file = await VaultMediaCache.getDecryptedOriginal(widget.item)
          .timeout(const Duration(minutes: 2));
      if (mounted) {
        setState(() => _file = file);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not load this photo. Tap to retry.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_file == null) {
      if (_error != null) {
        return Center(
          child: TextButton(
            onPressed: () {
              setState(() => _error = null);
              _load();
            },
            child: Text(_error!),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final viewportPx =
        (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context))
            .round();
    return InteractiveViewer(
      transformationController: _transform,
      minScale: 1.0,
      maxScale: 4.0,
      child: Center(
        // Bounded at the viewport until the user actually zooms. A
        // 12-megapixel original decoded at source resolution is ~48MB of raster
        // to fill a screen that cannot show a tenth of it — and it is decoded
        // on the page BEFORE the user has finished swiping to it.
        //
        // The upgrade costs one decode and NO network: the bytes are already
        // decrypted and resident by the time anyone can pinch.
        child: _zoomed
            ? Image.file(_file!, fit: BoxFit.contain)
            : Image.file(_file!, fit: BoxFit.contain, cacheWidth: viewportPx),
      ),
    );
  }
}

class _NotePage extends StatefulWidget {
  const _NotePage({required this.item});
  final VaultItem item;

  @override
  State<_NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<_NotePage> {
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await decryptVaultNote(widget.item);
      if (mounted) setState(() => _text = text);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not decrypt: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    if (_text == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Text(
          _text!,
          style: const TextStyle(
            color: Color(0xFFFBF8F4),
            fontSize: 24,
            height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.item});
  final VaultItem item;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await VaultMediaCache.getDecryptedOriginal(widget.item)
          .timeout(const Duration(minutes: 2));
      if (!mounted) return;
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      await controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (_) {
      if (mounted)
        setState(() {
          _error = 'Could not load this video.';
          _loading = false;
        });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Center(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _controller!.value.isPlaying
                ? _controller!.pause()
                : _controller!.play();
          });
        },
        child: AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_controller!),
              if (!_controller!.value.isPlaying)
                const Icon(Icons.play_arrow, size: 80, color: Colors.white54),
            ],
          ),
        ),
      ),
    );
  }
}
