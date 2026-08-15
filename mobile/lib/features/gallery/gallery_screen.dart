import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/features/gallery/gallery_repository.dart';
import 'package:miles/features/gallery/gallery_viewer.dart';

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

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  Stream<List<GalleryItem>>? _stream;
  int _uploading = 0;

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
      _stream = GalleryRepository.stream(coupleId);
    }
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

    setState(() => _uploading = picked.length);
    for (final item in picked) {
      try {
        await GalleryRepository.upload(
          coupleId: coupleId,
          uploadedBy: me,
          file: item.file,
          mimeType: item.isVideo ? 'video/mp4' : 'image/jpeg',
        );
      } catch (_) {
        // Never the exception. One failed picture out of thirty must not read
        // as a backend error message.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("One picture didn't upload.")),
          );
        }
      } finally {
        if (mounted) setState(() => _uploading--);
      }
    }
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
          stream: _stream,
          builder: (context, snap) {
            if (snap.hasError) {
              return const _Message('Could not load the gallery. Pull to retry.');
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data!;
            if (items.isEmpty) {
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
                    itemCount: items.length,
                    itemBuilder: (context, i) => _Tile(
                      item: items[i],
                      selected: _selected.contains(items[i].id),
                      selecting: _selecting,
                      onTap: () => _selecting
                          ? _toggle(items[i].id)
                          : _open(items, i),
                      onLongPress: () => _toggle(items[i].id),
                    ),
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
            "It stays until you agree. Deleted, the files are erased — it "
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
                fit: BoxFit.cover,
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
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0x99F5EFE6), height: 1.5),
          ),
        ),
      );
}
