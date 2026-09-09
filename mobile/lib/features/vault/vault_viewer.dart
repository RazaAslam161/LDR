import 'dart:async';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/media/plain_media_cache.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:miles/features/vault/vault_video_server.dart';
import 'package:video_player/video_player.dart';

/// Full-screen vault media, swipeable, decrypted in-process.
///
/// The vault used to mint a signed URL and hand it to the system browser. That
/// leaked the contents into another app's cache and history, showed a URL bar
/// over something PIN-gated, and broke outright once the signature expired —
/// which for saved photos and voice notes was within a day, by construction.
class VaultViewer extends StatefulWidget {
  const VaultViewer({
    required this.items,
    required this.initialIndex,
    super.key,
  });

  /// Owned media only. A legacy bookmark row has no bytes to show.
  final List<VaultItem> items;
  final int initialIndex;

  @override
  State<VaultViewer> createState() => _VaultViewerState();
}

class _VaultViewerState extends State<VaultViewer> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  /// Pages either side whose FILE is pulled down ahead of the swipe.
  static const _warmRadius = 2;

  bool _warming = false;

  /// A [_warm] arrived while one was running. Without it the last swipe of a
  /// burst is the one page whose neighbours never get warmed.
  bool _warmAgain = false;

  @override
  void initState() {
    super.initState();
    unawaited(_warm());
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Sign and download the neighbours before the finger reaches them.
  ///
  /// This screen had nothing of the kind: no `allowImplicitScrolling`, so
  /// PageView's cache extent was zero and no neighbour page was ever built,
  /// and no warm, so arriving on one started the whole sign-download-decode
  /// chain from cold. Every swipe in the vault was a first open.
  ///
  /// Plaintext rows only. A legacy `.enc` object needs the vault key derived
  /// and its associated data built per item, which is `_Page`'s job and not
  /// worth duplicating here for a page nobody may reach.
  Future<void> _warm() async {
    if (_warming) {
      _warmAgain = true;
      return;
    }
    _warming = true;
    try {
      for (var d = 1; d <= _warmRadius; d++) {
        for (final direction in const [1, -1]) {
          final i = _index + d * direction;
          if (i < 0 || i >= widget.items.length) continue;
          final item = widget.items[i];
          final path = item.storagePath;
          // A video streams from its URL; pulling tens of megabytes down for
          // a page nobody has swiped to is the opposite of this.
          if (path == null || path.endsWith('.enc') ||
              item.isVideo || item.isAudio) {
            continue;
          }
          final url = MediaUrls.cached(VaultRepository.bucket, path) ??
              await MediaUrls.sign(VaultRepository.bucket, path);
          if (!mounted) return;
          if (url == null) continue;
          try {
            await PlainMediaCache.manager.getSingleFile(url,
                key: PlainMediaCache.keyFor(VaultRepository.bucket, path),);
          } catch (_) {
            // A warm that misses costs one wheel on one page. Never worth
            // failing a swipe for.
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

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: MilesColors.cream50),
        title: Text(
          item.mediaUrl ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: MilesColors.cream50, fontSize: 14),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: PageView.builder(
        controller: _pages,
        // Exactly one page either side is built ahead. Left at its `false`
        // default, PageView's cache extent is ZERO — no neighbour page exists
        // until the swipe has already landed on it, so every page in this
        // vault mounted cold and ran its whole sign-download-decode chain
        // while the user was looking at the result. The chat and gallery
        // pagers have carried this flag for as long as they have swiped well.
        allowImplicitScrolling: true,
        itemCount: widget.items.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          unawaited(_warm());
        },
        itemBuilder: (_, i) => _Page(item: widget.items[i]),
      ),
    );
  }
}

class _Page extends StatefulWidget {
  const _Page({required this.item});
  final VaultItem item;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  ImageProvider? _provider;
  String? _error;
  VaultVideoServer? _server;
  VideoPlayerController? _vp;
  ChewieController? _chewie;

  /// Seeds [_provider] with whatever this process has already resolved, before
  /// [_load] gets a chance to await anything.
  ///
  /// Every path through `_load` is a Future, so opening a photograph the vault
  /// grid decoded a second ago still painted the wheel for a frame or more —
  /// which is the loading wheel on media that has already been seen. Nothing
  /// here fetches, signs or decrypts: a null simply means there was nothing to
  /// paint yet and `_load` does the real work either way.
  void _paintWarm() {
    final legacy = widget.item.legacyIntimatePath;
    if (widget.item.isVideo || widget.item.isAudio) return;
    if (legacy != null) {
      if (legacy.toLowerCase().endsWith('.mp4')) return;
      _provider = PlainMediaCache.warm(
          privateBucket, MediaUrls.toPath(privateBucket, legacy),);
      return;
    }
    final path = widget.item.storagePath;
    if (path == null) return;
    // The TILE, not the original — for the same reason the `.enc` branch below
    // reaches for one. The grid downloaded and decoded the thumbnail; the
    // original may never have been fetched, and seeding a provider for bytes
    // that are not here yet paints a black frame with no wheel over it, which
    // is exactly the silent blank build() already refuses to show.
    // `_loadPlainImage` swaps the original in over it, gaplessly.
    final grid = widget.item.gridPath ?? path;
    if (!path.endsWith('.enc')) {
      _provider = PlainMediaCache.warm(VaultRepository.bucket, grid);
      return;
    }
    _provider = EncryptedMediaCache.warmTileProvider(
        bucket: VaultRepository.bucket, path: grid,);
  }

  /// Legacy rows are PLAINTEXT in the couple's bucket, so they are fetched by
  /// signed URL rather than decrypted. Read-only by design: nothing re-writes
  /// them, and re-saving is what moves an item into the vault's own storage.
  Future<void> _loadLegacy(String path) async {
    try {
      final url = await ChatRepository.signedVideoUrl(path);
      if (url == null) {
        if (mounted) setState(() => _error = "This one couldn't be opened.");
        return;
      }
      if (widget.item.isVideo || widget.item.isAudio ||
          path.toLowerCase().endsWith('.mp4')) {
        final vp = VideoPlayerController.networkUrl(Uri.parse(url));
        await vp.initialize();
        if (!mounted) {
          await vp.dispose();
          return;
        }
        setState(() {
          _vp = vp;
          _chewie = ChewieController(
            videoPlayerController: vp,
            autoPlay: true,
            deviceOrientationsAfterFullScreen: const [
              DeviceOrientation.portraitUp,
            ],
          );
        });
        return;
      }
      if (mounted) {
        setState(() => _provider = PlainMediaCache.provider(
              privateBucket, MediaUrls.toPath(privateBucket, path), url,),);
      }
    } catch (e) {
      if (mounted) setState(() => _error = "This one couldn't be opened.");
    }
  }

  Future<void> _loadPlainImage(String path) async {
    try {
      final url = MediaUrls.cached(VaultRepository.bucket, path) ??
          await MediaUrls.sign(VaultRepository.bucket, path);
      if (!mounted) return;
      if (url == null) {
        setState(() => _error = "This one couldn't be opened.");
        return;
      }
      // NOT NetworkImage: no disk cache, and keyed on a token that rotates
      // daily, so re-opening the same photograph downloaded it again.
      setState(() => _provider =
          PlainMediaCache.provider(VaultRepository.bucket, path, url),);
    } catch (e) {
      if (mounted) setState(() => _error = "This one couldn't be opened.");
    }
  }

  /// Plaintext video/audio: a signed URL straight into the player — no
  /// decrypt, no loopback server.
  Future<void> _loadPlainPlayable(String path) async {
    try {
      final url = MediaUrls.cached(VaultRepository.bucket, path) ??
          await MediaUrls.sign(VaultRepository.bucket, path);
      if (url == null) {
        if (mounted) setState(() => _error = "This one couldn't be opened.");
        return;
      }
      final vp = VideoPlayerController.networkUrl(Uri.parse(url));
      await vp.initialize();
      if (!mounted) {
        await vp.dispose();
        return;
      }
      setState(() {
        _vp = vp;
        _chewie = ChewieController(
          videoPlayerController: vp,
          autoPlay: true,
          deviceOrientationsAfterFullScreen: const [
            DeviceOrientation.portraitUp,
          ],
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = "This one couldn't be opened.");
    }
  }

  /// Decrypts in memory and plays from loopback. See [VaultVideoServer] for why
  /// this does not decrypt to a file.
  Future<void> _loadPlayable(String path) async {
    if (!path.endsWith('.enc')) {
      await _loadPlainPlayable(path);
      return;
    }
    try {
      final bytes = await EncryptedMediaCache.bytes(
        bucket: VaultRepository.bucket,
        path: path,
        associatedData: VaultRepository.fullAdFor(widget.item.id),
        keyOverride: await CryptoCore.exportVaultKeyBytes(),
      );
      final server = await VaultVideoServer.start(
        bytes: bytes,
        mimeType: widget.item.mimeType ?? 'video/mp4',
      );
      final vp = VideoPlayerController.networkUrl(server.url);
      await vp.initialize();
      if (!mounted) {
        await server.close();
        await vp.dispose();
        return;
      }
      setState(() {
        _server = server;
        _vp = vp;
        _chewie = ChewieController(
          videoPlayerController: vp,
          autoPlay: true,
          deviceOrientationsAfterFullScreen: const [
            DeviceOrientation.portraitUp,
          ],
          materialProgressColors: ChewieProgressColors(
            playedColor: MilesColors.ember,
            handleColor: MilesColors.ember,
          ),
        );
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = "This one couldn't be played.");
      }
    }
  }

  @override
  void dispose() {
    // Chewie first: it touches the VideoPlayerController while tearing its own
    // controls down. Then the controller, then the socket — closing the server
    // first would pull the stream out from under a live decoder.
    _chewie?.dispose();
    _vp?.dispose();
    unawaited(_server?.close() ?? Future<void>.value());
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _paintWarm();
    _load();
  }

  Future<void> _load() async {
    // A legacy row still points at real bytes in the couple's shared bucket.
    // Refusing it was a regression: the build before this one re-signed a URL
    // and the item opened. Only a row holding a bare signed URL is truly dead,
    // because that signature expired within a day of being saved.
    final legacy = widget.item.legacyIntimatePath;
    if (legacy != null) {
      await _loadLegacy(legacy);
      return;
    }
    final path = widget.item.storagePath;
    if (path == null) {
      setState(() => _error =
          'Saved as a link that has since expired. Re-save it from the '
          'original message and the vault will keep its own copy.');
      return;
    }
    if (widget.item.isVideo || widget.item.isAudio) {
      await _loadPlayable(path);
      return;
    }
    if (!path.endsWith('.enc')) {
      // Plaintext row: the gallery mechanism — sign, then stream. Same road
      // the legacy couple-bucket rows have always taken.
      await _loadPlainImage(path);
      return;
    }
    // The grid already decrypted the 400px tile into memory — paint it NOW
    // and let the original replace it in place. A black screen with a wheel
    // while a multi-MB original signs, downloads and decrypts was the
    // reported symptom, with this preview resident the whole time.
    final gridPath = widget.item.gridPath;
    if (gridPath != null) {
      try {
        final tile = await EncryptedMediaCache.tileProvider(
          bucket: VaultRepository.bucket,
          path: gridPath,
          associatedData: widget.item.thumbPath != null
              ? VaultRepository.thumbAdFor(widget.item.id)
              : VaultRepository.fullAdFor(widget.item.id),
          keyOverride: await CryptoCore.exportVaultKeyBytes(),
        );
        if (mounted && _provider == null) setState(() => _provider = tile);
      } catch (_) {
        // A head start, not the load. The full path below is the real one
        // and carries the real error message.
      }
    }
    try {
      final p = await EncryptedMediaCache.fullProvider(
        bucket: VaultRepository.bucket,
        path: path,
        associatedData: VaultRepository.fullAdFor(widget.item.id),
        keyOverride: await CryptoCore.exportVaultKeyBytes(),
      );
      if (mounted) setState(() => _provider = p);
    } catch (e) {
      if (mounted) {
        // The tile may already be up — keep showing it rather than swapping a
        // visible picture for an error sentence.
        if (_provider == null) {
          setState(() => _error = "This one couldn't be opened.");
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
          ),
        ),
      );
    }
    final chewie = _chewie;
    if (chewie != null) {
      return Center(
        child: AspectRatio(
          aspectRatio: _vp!.value.aspectRatio,
          child: Chewie(controller: chewie),
        ),
      );
    }
    final provider = _provider;
    if (provider == null) {
      // Never a bare empty frame: that combination — no image, no message, no
      // spinner — is the silent blank that made memory covers look broken.
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Center(
        child: Image(
          image: provider,
          fit: BoxFit.contain,
          // The tile is painted first and the original swaps in over it —
          // without this the swap blanks for a frame.
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const Center(
            child: Text(
              "This one couldn't be displayed.",
              style: TextStyle(color: MilesColors.taupe, fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }
}
