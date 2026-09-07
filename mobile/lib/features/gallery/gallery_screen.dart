import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/services/storage_quota.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/features/gallery/gallery_repository.dart';
import 'package:miles/features/gallery/gallery_viewer.dart';
import 'package:miles/features/safety/report_service.dart';
import 'package:miles/features/safety/safety_sheets.dart';

/// The couple's shared gallery — one roll, both of them, like the gallery
/// already on the phone.
///
/// Every rule that makes this fast is inherited from the chat pipeline rather
/// than reinvented: a small thumbnail object per picture, ONE decode width
/// shared by every surface that paints it, `memCacheHeight` never set, disk
/// caching keyed by path rather than by an expiring signed URL, and a batch
/// sign before the first tile builds.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  /// Sign-out hook. The failed-upload record is static so a cover raise
  /// cannot erase it — which also makes it survive a SIGN-OUT, and a failed
  /// tile renders the previous account's actual photograph from disk to
  /// whoever signs in next. _endSession() calls this beside the other
  /// process-scoped clears (MediaUrls, ChatSendQueue, the caches).
  static void clearFailedUploads() => _GalleryScreenState._failed.clear();

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  Stream<List<GalleryItem>>? _stream;
  int _uploading = 0;

  /// Picked files whose upload failed, kept as retryable tiles at the top of
  /// the grid instead of evaporating with a snackbar's four seconds.
  ///
  /// STATIC on purpose: backgrounding raises the cover, which destroys this
  /// State while the loop may still be running, and an instance list would
  /// take the only record of what failed down with it. Each entry carries the
  /// couple it was picked for, so a retry after an account switch posts to the
  /// original couple or fails RLS — never the wrong gallery. Process death
  /// still loses everything here: these are in-memory paths into the picker's
  /// cache, and surviving that would take a persisted queue, which this is
  /// deliberately not.
  static final List<_PendingUpload> _failed = [];

  /// Ids picked in selection mode. Empty set = not selecting; a long-press
  /// starts it, which is what a phone's own gallery does, so nobody has to be
  /// told.
  final Set<String> _selected = {};
  bool _busy = false;

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coupleId = ref.read(sessionProvider).couple?.id;
    if (coupleId != null && _stream == null) {
      _window = GalleryRepository.window(coupleId);
      _stream = _window!.stream;
      _grid.addListener(_onGridScroll);
    }
  }

  /// The live grid, and the handle that can page behind its 500-item seed.
  GalleryWindow? _window;

  final _grid = ScrollController();

  /// Ask for the next page while there is still a screenful to scroll through,
  /// so the pictures are usually in hand before the finger reaches them.
  void _onGridScroll() {
    if (!_grid.hasClients) return;
    if (_grid.position.extentAfter > 600) return;
    final w = _window;
    if (w == null || w.busy || w.atEnd) return;
    unawaited(w.more().then((_) {
      // The window is not a notifier; the stream only emits when rows were
      // actually ADDED, so a page that ended the list or failed has to
      // repaint the footer itself.
      if (mounted) setState(() {});
    }));
  }

  /// Held true from a Try again tap for one beat — see the builder, which is
  /// where it earns its keep.
  bool _retrying = false;
  Timer? _retryHold;

  /// The only thing that re-runs a failed first fetch.
  ///
  /// The repository seeds its broadcast controller once, on first listen, so
  /// after `addError` nothing re-reads for the life of this subscription — a
  /// fresh stream is the retry. The error copy used to say "Pull to retry" on
  /// a screen with no RefreshIndicator on it or above it in the router, which
  /// left a routine backend failure (a paused project, a phone off the
  /// network) as a dead end with a gesture that does not exist.
  void _retry() {
    final coupleId = ref.read(sessionProvider).couple?.id;
    if (coupleId == null) {
      // Unlinked between the failure and the tap — there is no gallery left to
      // build a stream for. Returning quietly was the dead button all over
      // again, in the one case where no amount of tapping can ever help.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You're not linked to anyone.")),
      );
      return;
    }
    _retryHold?.cancel();
    _retryHold = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _retrying = false);
    });
    setState(() {
      _retrying = true;
      _window?.dispose();
      _window = GalleryRepository.window(coupleId);
      _stream = _window!.stream;
    });
  }

  @override
  void dispose() {
    _retryHold?.cancel();
    _grid.dispose();
    _window?.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final session = ref.read(sessionProvider);
    final coupleId = session.couple?.id;
    final me = session.profile?.id;
    if (coupleId == null || me == null) return;

    // Through PhotoPickerService, never a bare ImagePicker: on Android the
    // default fires ACTION_GET_CONTENT, which opens the document provider —
    // the "it opens the file manager, not my gallery" complaint, already fixed
    // twice elsewhere. It also brings HEIC/ProRAW conversion.
    final picked = await PhotoPickerService.pickMedia(limit: 30);
    final skipped = PhotoPickerService.takeRejectedFormats();
    if (skipped.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("This phone can't read "
              '${skipped.map((e) => '.$e').join(', ')}'),
        ),
      );
    }
    if (picked.isEmpty) return;

    await _upload([
      for (final item in picked)
        _PendingUpload(
          coupleId: coupleId,
          uploadedBy: me,
          file: item.file,
          isVideo: item.isVideo,
        ),
    ]);
  }

  /// Uploads [batch] one at a time, keeping whatever fails in [_failed].
  ///
  /// The old loop showed "One picture didn't upload." per failure — naming no
  /// picture and offering no way to send it — and dropped the file on the
  /// floor. Now a failure stays visible as a tile until it uploads or the
  /// process dies, and the snackbar says how many and offers Retry.
  Future<void> _upload(List<_PendingUpload> batch) async {
    if (mounted) setState(() => _uploading += batch.length);
    var failed = 0;
    // Counted apart from [failed] because these must never be offered a Retry:
    // the file is bigger than the bucket accepts and every attempt ends the
    // same way. They are dropped from the queue here rather than left as
    // failed tiles the user taps forever.
    var oversize = 0;
    var oversizeMb = 0;
    // Kept so the sentence below can ask what the refusal actually was.
    Object? lastError;
    for (final item in batch) {
      try {
        await GalleryRepository.upload(
          coupleId: item.coupleId,
          uploadedBy: item.uploadedBy,
          file: item.file,
          mimeType: item.isVideo ? 'video/mp4' : 'image/jpeg',
        );
      } on GalleryTooLarge catch (e) {
        oversize++;
        if (e.megabytes > oversizeMb) oversizeMb = e.megabytes;
      } catch (e, st) {
        // Never the exception text to the user — one failed picture out of
        // thirty must not read as a backend error message. Reported though,
        // because a fleet whose uploads fail quietly looks exactly like a
        // fleet whose users stopped adding pictures.
        ErrorReporter.report(e, st, kind: 'gallery');
        lastError = e;
        failed++;
        _failed.add(item);
      } finally {
        if (mounted) setState(() => _uploading--);
      }
    }
    // Said first and on its own: it names a cause the user can act on, and
    // "check your connection" over a file that is simply too big is the app
    // sending somebody to their router over a video.
    if (oversize > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(oversize == 1
              ? 'That one is ${oversizeMb}MB — too big to add. '
                  'The limit is ${GalleryRepository.maxUploadBytes ~/ (1024 * 1024)}MB.'
              : '$oversize were too big to add. The limit is '
                  '${GalleryRepository.maxUploadBytes ~/ (1024 * 1024)}MB each.'),
        ),
      );
    }
    if (failed > 0 && mounted) {
      // A refused upload and a lost connection look identical in the
      // exception, so the account's own counter is asked before the sentence
      // is chosen. Sending someone to their router over a full account is the
      // same mistake the oversize branch above exists to avoid.
      final sentence = lastError == null
          ? null
          : await StorageQuota.explain(lastError, fallback: '');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sentence != null && sentence.isNotEmpty
              ? sentence
              : failed == batch.length
                  ? 'Nothing uploaded — check your connection.'
                  : "$failed of ${batch.length} didn't upload.",),
          action: SnackBarAction(label: 'Retry', onPressed: _retryAll),
        ),
      );
    }
  }

  /// The snackbar's Retry: every failed item, one batch. No setState — the
  /// first thing [_upload] does is one, and this can be tapped from a snackbar
  /// that outlived the screen.
  void _retryAll() {
    final again = List.of(_failed);
    if (again.isEmpty) return;
    _failed.clear();
    unawaited(_upload(again));
  }

  /// A failed tile's tap: just that one.
  void _retryOne(_PendingUpload item) {
    if (!_failed.remove(item)) return; // a second tap raced the first
    unawaited(_upload([item]));
  }

  /// Asks about the selection, and says plainly when some of it could not be
  /// asked about.
  ///
  /// The RPC returns how many rows it actually moved, so a silent shortfall is
  /// visible here rather than looking like the button did nothing: an item
  /// already pending, or one refused three times, is skipped server-side.
  Future<void> _askToDelete() async {
    final ids = _selected.toList();
    setState(() => _busy = true);
    try {
      final n = await GalleryRepository.requestDelete(ids);
      if (!mounted) return;
      setState(_selected.clear);
      final blocked = ids.length - n;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            blocked == 0
                ? '$n waiting for your partner'
                : '$n waiting · $blocked already settled or pending',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That didn't go through. Try again.")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(_selected.clear),
              )
            : null,
        title: Text(_selecting ? '${_selected.length} selected' : 'Gallery'),
        actions: [
          if (_selecting)
            IconButton(
              tooltip: 'Ask to delete',
              onPressed: _busy ? null : _askToDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          if (_selecting)
            IconButton(
              tooltip: 'Report',
              // One id even when several are picked. The report is about a
              // thing, and a list of ids in a 200-character field would be
              // truncated into something nobody could line up with a row.
              onPressed: _busy
                  ? null
                  : () => showReportSheet(context,
                      target: ReportTarget.galleryItem,
                      targetRef: _selected.first,),
              icon: const Icon(Icons.flag_outlined),
            ),
          if (_uploading > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('$_uploading…',
                    style: const TextStyle(fontSize: 12),),
              ),
            ),
          IconButton(
            onPressed: _uploading > 0 ? null : _add,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<List<GalleryItem>>(
          // Keyed by the stream OBJECT, and that key IS the retry.
          //
          // StreamBuilder carries its snapshot across a stream swap:
          // didUpdateWidget runs afterDisconnected then afterConnected, and
          // both go through AsyncSnapshot.inState, whose own doc says data,
          // error and stackTrace "persist unmodified". So `hasError` stayed
          // true from the dead stream and the second failure repainted the
          // FIRST failure's card — byte-identical, no spinner between them.
          // Try again looked wired to nothing. A new key builds a new element
          // with an empty snapshot, so a dead stream's error cannot outlive the
          // stream it came from.
          key: ObjectKey(_stream),
          stream: _stream,
          builder: (context, snap) {
            // Held for a beat even when the replacement stream fails at once:
            // a repeat failure that repaints the same card inside one frame is
            // indistinguishable from a tap that did nothing, which is the whole
            // complaint. Data is never held — it falls straight through.
            if (_retrying && !snap.hasData) {
              return const _Message('Trying again…', busy: true);
            }
            if (snap.hasError) {
              return _Message(
                'Could not load the gallery.',
                onRetry: _retry,
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data!;
            if (items.isEmpty && _failed.isEmpty) {
              return const _Message(
                'Nothing here yet.\nAdd the first one.',
              );
            }
            final me = ref.read(sessionProvider).profile?.id ?? '';
            final awaiting =
                items.where((i) => i.awaitingMe(me)).toList();
            return Column(
              children: [
                // Pinned above the grid, addressed to whoever is reading. The
                // person who asked sees nothing here — there is nothing for
                // them to do but wait, and a banner they cannot act on is
                // noise.
                if (awaiting.isNotEmpty && !_selecting)
                  _ConsentBand(
                    count: awaiting.length,
                    busy: _busy,
                    onKeep: () => _answer(
                        awaiting, GalleryRepository.cancelDelete, 'kept',),
                    onDelete: () => _answer(
                        awaiting, GalleryRepository.confirmDelete, 'deleted',),
                  ),
                Expanded(
                  child: GridView.builder(
                    controller: _grid,
                    padding: const EdgeInsets.all(2),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 2,
                      mainAxisSpacing: 2,
                    ),
                    // Square cells, fixed by the delegate — so a tile occupies
                    // its final shape from the first frame and nothing below it
                    // moves when a picture arrives. BoxFit.cover does the rest.
                    //
                    // Failed uploads lead the grid: they are the newest thing
                    // the user did, and the top is where their picture would
                    // have appeared if it had gone through.
                    itemCount: _failed.length + items.length,
                    itemBuilder: (context, i) {
                      if (i < _failed.length) {
                        final f = _failed[i];
                        return _FailedTile(
                          item: f,
                          onRetry: () => _retryOne(f),
                        );
                      }
                      final at = i - _failed.length;
                      return _Tile(
                        item: items[at],
                        selected: _selected.contains(items[at].id),
                        selecting: _selecting,
                        onTap: () => _selecting
                            ? _toggle(items[at].id)
                            : _open(items, at),
                        onLongPress: () => _toggle(items[at].id),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Answers the partner's request for the whole pending set at once.
  Future<void> _answer(
    List<GalleryItem> items,
    Future<int> Function(List<String>) op,
    String noun,
  ) async {
    setState(() => _busy = true);
    try {
      final n = await op(items.map((i) => i.id).toList());
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$n $noun')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That didn't go through. Try again.")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(List<GalleryItem> items, int index) {
    // Sign the originals around the tap BEFORE the pager mounts, so page one
    // paints from cache rather than from a round trip.
    unawaited(GalleryRepository.warmOriginals(items, index));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GalleryViewer(items: items, initialIndex: index),
      ),
    );
  }
}

/// The band the OTHER partner sees. Deliberately not a dialog: the request may
/// cover eleven pictures, and the answer is one decision about the set.
class _ConsentBand extends StatelessWidget {
  const _ConsentBand({
    required this.count,
    required this.busy,
    required this.onKeep,
    required this.onDelete,
  });

  final int count;
  final bool busy;
  final VoidCallback onKeep;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: MilesColors.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == 1
                ? 'She asked to delete 1 picture.'
                : 'She asked to delete $count pictures.',
            style: const TextStyle(
              color: Color(0xFFFBF8F4),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'It stays until you agree. Deleted, the files are erased — it '
            "can't be undone.",
            style: TextStyle(fontSize: 12, color: Color(0x99F5EFE6)),
          ),
          const SizedBox(height: 10),
          // Both halves are Expanded, and that is load-bearing rather than
          // cosmetic.
          //
          // The app's FilledButton theme sets
          // `minimumSize: Size.fromHeight(56)`, and Size.fromHeight puts
          // double.infinity in the WIDTH. In a Row that is an unbounded demand:
          // the row overflows and "Delete them" is clipped straight off the
          // right edge, while "Keep them" — a TextButton, with no such minimum
          // — renders fine. The partner saw one button and reasonably concluded
          // there was no way to agree.
          //
          // Any FilledButton this theme places in a Row has the same problem.
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: busy ? null : onKeep,
                  child: const Text('Keep them'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onDelete,
                  child: const Text('Delete them'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One picked file that never reached the bucket. It carries everything a
/// retry needs, because by the time Retry is tapped the session may not be
/// the one it was picked under.
class _PendingUpload {
  _PendingUpload({
    required this.coupleId,
    required this.uploadedBy,
    required this.file,
    required this.isVideo,
  });

  final String coupleId;
  final String uploadedBy;
  final File file;
  final bool isVideo;
}

/// A picked file that didn't upload, held in the grid where the picture would
/// have appeared. Tapping retries that one file. Local by nature — the partner
/// never sees these.
class _FailedTile extends StatelessWidget {
  const _FailedTile({required this.item, required this.onRetry});

  final _PendingUpload item;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRetry,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.isVideo)
            // No cheap local video thumbnail without a decoder session; the
            // label below carries the state.
            const ColoredBox(color: MilesColors.surface2)
          else
            Image.file(
              item.file,
              fit: BoxFit.cover,
              // Bounded like the thumbnail pipeline's decode width — this is a
              // full-resolution original painting into a 3-across cell.
              cacheWidth: 400,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: MilesColors.surface2),
            ),
          // scrim over the photograph, so the failed state reads on any picture
          const ColoredBox(color: Color(0x99000000)),
          const Center(
            child: Icon(Icons.refresh, color: Color(0xFFFBF8F4), size: 24),
          ),
          const Positioned(
            left: 4,
            right: 4,
            bottom: 6,
            child: Text(
              "Didn't upload — tap to retry",
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xCCFBF8F4), fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.item,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.selecting = false,
  });

  final GalleryItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selected;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final url = MediaUrls.cached(privateBucket, item.gridPath);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Hero(
        tag: 'gallery-${item.id}',
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url == null)
              // A miss paints the surface, never a spinner. The URL is warmed
              // in one batch before the grid builds, so this is the rare case,
              // and a wheel per tile is exactly what the old vault looked like.
              const ColoredBox(color: MilesColors.surface2)
            else
              NetImage(
                url,
                // Keyed by PATH, not by the signed URL — a token expires daily
                // and would re-download every picture the day after it was
                // first seen.
                cacheKey: '$privateBucket/${item.gridPath}',
                // The object is already ~400px, so bounding its decode buys
                // nothing and costs sharing: unbounded, every surface painting
                // this thumbnail shares one decode.
                thumb: true,
              ),
            if (item.isVideo)
              const Center(
                child: Icon(Icons.play_circle_fill,
                    size: 28, color: Color(0xCCFBF8F4),),
              ),
            // Pending removal reads on the tile itself, so the person who asked
            // can see what they asked about without a list to cross-reference.
            // A settled item is marked differently: it is kept, permanently,
            // and showing it as merely "pending" would invite a fourth ask that
            // the server will refuse.
            if (item.deleteSettled)
              const Positioned(
                right: 4,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // scrim over the photograph, so the glyph stays legible
                    // whatever the picture behind it happens to be
                    color: Color(0x99000000),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(Icons.lock_outline,
                        size: 13, color: Color(0xFFF5EFE6),),
                  ),
                ),
              )
            else if (item.deleteRequested)
              const Positioned(
                right: 4,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // scrim over the photograph, so the glyph stays legible
                    // whatever the picture behind it happens to be
                    color: Color(0x99000000),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(Icons.hourglass_top,
                        size: 13, color: Color(0xFFEF6F58),),
                  ),
                ),
              ),
            if (selecting)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected
                        ? const Color(0xFFEF6F58)
                        : const Color(0xCCFBF8F4),
                  ),
                ),
              ),
            if (selected)
              // scrim over the photo, marking the picked ones at a glance
              const ColoredBox(color: Color(0x552B1B12)),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry, this.busy = false});
  final String text;

  /// Present only on the failure state — which is what separates it from the
  /// empty one, since both are otherwise this same card.
  final VoidCallback? onRetry;

  /// A retry is in flight. The button becomes the spinner it started, so the
  /// tap is visible for its own sake rather than only when it happens to
  /// succeed.
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/art/frame.webp', width: 132, height: 132),
              const SizedBox(height: 12),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0x99F5EFE6), height: 1.5),
              ),
              if (busy) ...[
                const SizedBox(height: 14),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ] else if (onRetry != null) ...[
                const SizedBox(height: 8),
                TextButton(onPressed: onRetry, child: const Text('Try again')),
              ],
            ],
          ),
        ),
      );
}
