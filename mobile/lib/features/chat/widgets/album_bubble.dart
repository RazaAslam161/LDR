import 'dart:io';

import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/net_image.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/media_album.dart';

/// A send of several photos or videos, drawn as one grid.
///
/// Twenty photos used to be twenty full-width bubbles: the conversation became
/// a mile of column, every one of them downloading its own original, and
/// scrolling past a holiday meant scrolling past every frame of it. This is the
/// same twenty as a single bubble the height of one.
///
/// Tiles are laid out the way every messenger lays them out, because that is
/// what the shape reads as: two side by side, three as one large and two
/// stacked, four or more as a 2×2 with the remainder counted on the last tile.
class AlbumBubble extends StatelessWidget {
  const AlbumBubble({
    required this.row,
    required this.onOpen,
    super.key,
  });

  final ChatRow row;

  /// Index within [ChatRow.items] — the pager opens on the tile that was hit.
  final void Function(int index) onOpen;

  /// Never more than four tiles regardless of how many were sent; the fourth
  /// carries the count of everything it stands for.
  static const _maxTiles = 4;

  static const _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    final items = row.items;
    final shown = items.length < _maxTiles ? items.length : _maxTiles;
    final hidden = items.length - shown;

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: switch (shown) {
          2 => 2,
          3 => 3 / 2,
          _ => 1,
        },
        child: switch (shown) {
          2 => Row(children: [
              _tile(items[0], 0, flex: 1),
              const SizedBox(width: _gap),
              _tile(items[1], 1, flex: 1),
            ],),
          3 => Row(children: [
              _tile(items[0], 0, flex: 2),
              const SizedBox(width: _gap),
              Expanded(
                child: Column(children: [
                  _tile(items[1], 1, flex: 1),
                  const SizedBox(height: _gap),
                  _tile(items[2], 2, flex: 1),
                ],),
              ),
            ],),
          _ => Column(children: [
              Expanded(
                child: Row(children: [
                  _tile(items[0], 0, flex: 1),
                  const SizedBox(width: _gap),
                  _tile(items[1], 1, flex: 1),
                ],),
              ),
              const SizedBox(height: _gap),
              Expanded(
                child: Row(children: [
                  _tile(items[2], 2, flex: 1),
                  const SizedBox(width: _gap),
                  _tile(items[3], 3, flex: 1, moreCount: hidden),
                ],),
              ),
            ],),
        },
      ),
    );
  }

  Widget _tile(Message m, int index, {required int flex, int moreCount = 0}) =>
      Expanded(
        flex: flex,
        child: _AlbumTile(
          message: m,
          moreCount: moreCount,
          onTap: () => onOpen(index),
        ),
      );
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.message,
    required this.moreCount,
    required this.onTap,
  });

  final Message message;

  /// How many further items the grid is not showing. Only ever non-zero on the
  /// last tile.
  final int moreCount;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final local = m.localPath;
    final url = m.tileUrl;

    // Optimistic sends paint the file off the disk, so a pick of twenty is a
    // full grid the instant it is accepted rather than twenty grey squares
    // filling in as the uploads land.
    // A grid tile is ~148dp at most and often ~100. Neither branch bounded its
    // decode, so a pick of twenty put twenty full-sensor images through the
    // decoder at once on the sender's phone, and the receiver decoded whatever
    // the original happened to be. Once a thumbnail exists the object IS the
    // bound and NetImage shares one decode across every surface showing it.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    const tileEdge = 160.0;
    final image = local != null
        ? Image.file(File(local),
            fit: BoxFit.cover,
            cacheWidth: (tileEdge * dpr).round(),
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: MilesColors.surface2),)
        : url != null
            ? NetImage(url,
                width: tileEdge,
                height: tileEdge,
                cacheKey: m.tileCacheKey,
                thumb: m.hasThumb,)
            : const ColoredBox(color: MilesColors.surface2);

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (m.kind == 'video' && moreCount == 0)
            const Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // scrim over the poster frame, so the play badge reads on a
                  // bright still as well as a dark one.
                  color: Color(0x66000000),
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 22,),
                ),
              ),
            ),
          if (m.sendStatus == SendStatus.sending)
            const ColoredBox(
              // scrim over the photo being uploaded — it stays visible
              // underneath, so the tile is the picture and not a grey square.
              color: Color(0x55000000),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white,),
                ),
              ),
            ),
          // A failed upload inside a grid is otherwise indistinguishable from
          // one that simply has not painted yet.
          if (m.sendStatus == SendStatus.failed)
            const ColoredBox(
              // scrim over the photo that did not upload, for the same reason.
              color: Color(0x55000000),
              child: Center(
                child: Icon(Icons.error_outline_rounded,
                    color: Colors.white, size: 22,),
              ),
            ),
          if (moreCount > 0)
            ColoredBox(
              // scrim over the fourth photo, which is still the tile's picture
              // — the count has to stay legible whatever it happens to be.
              color: const Color(0x99000000),
              child: Center(
                child: Text(
                  '+$moreCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
