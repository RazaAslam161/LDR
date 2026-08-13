import 'package:flutter/foundation.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/media_decode.dart';

/// One thing a full-screen viewer can show.
///
/// A PATH and a bucket, never a URL. Every bucket is private and every URL
/// carries a token that dies within the day, so a viewer that is handed a URL
/// can only ever paint a broken icon once it expires — it has nothing left to
/// re-sign from. The path is what the database holds and what survives.
@immutable
class MediaItem {
  const MediaItem({
    required this.bucket,
    required this.path,
    this.thumbPath,
    this.isVideo = false,
    this.senderName = 'a message',
    this.sentAt,
    Object? heroTag,
  }) : _heroTag = heroTag;

  /// From a value read out of a table: a storage path, or one of the legacy
  /// `/object/public/...` URLs written before the buckets closed.
  factory MediaItem.stored(
    String bucket,
    String value, {
    String? thumbPath,
    bool isVideo = false,
    String senderName = 'a message',
    DateTime? sentAt,
    Object? heroTag,
  }) =>
      MediaItem(
        bucket: bucket,
        path: MediaUrls.toPath(bucket, value),
        thumbPath: thumbPath,
        isVideo: isVideo,
        senderName: senderName,
        sentAt: sentAt,
        heroTag: heroTag,
      );

  final String bucket;
  final String path;

  /// The small sibling object, in the same [bucket], or null for anything
  /// written before thumbnails existed.
  final String? thumbPath;

  final bool isVideo;

  /// What a TILE paints. The pager always reads [path] — it is the one place
  /// the full resolution is actually wanted.
  String get tilePath => thumbPath ?? path;

  /// Files a tile's bytes separately from the original's, so a grid and a
  /// viewer of the same photo do not fight over one cache entry.
  String get tileCacheKey => '$bucket/$tilePath';

  /// A real thumbnail sibling exists for this item.
  bool get hasThumb => thumbPath != null;

  /// The width every surface must decode this item's TILE at.
  ///
  /// A real thumbnail is already ~720px on its longest edge, so it is decoded
  /// unbounded and one frame serves the grid, the viewer's underlay and the
  /// precache. A legacy original has no such bound and would decode at source
  /// resolution into a tile, so it is capped.
  int? get tileDecodeWidth => hasThumb ? null : kTileDecodePx;

  /// Whose it is, for the vault label a save writes.
  final String senderName;
  final DateTime? sentAt;

  final Object? _heroTag;

  /// What the disk cache files these bytes under.
  ///
  /// The signed URL rotates every 24h. Keyed by URL, the whole library
  /// re-downloads the next day and the cache fills with duplicates of bytes it
  /// already has; keyed by this, a re-sign costs nothing and the grid's
  /// download and the viewer's download are the same file.
  String get cacheKey => '$bucket/$path';

  /// The tile this flies from. Defaults to [cacheKey] so a grid and its pager
  /// agree without either of them inventing a tag.
  Object get heroTag => _heroTag ?? cacheKey;
}

/// The ordered set a pager pages through, and the grid in front of it.
///
/// One object, not two lists. The pager has to be able to swipe past what the
/// grid has loaded and the grid has to know about what the pager loaded —
/// otherwise you swipe to item 200, press Back, and the grid is still thirty
/// tiles tall with nothing to fly home to.
abstract class MediaSource extends ChangeNotifier {
  int get length;

  MediaItem itemAt(int index);

  /// Ask for the next page. Idempotent and fire-and-forget: called from a
  /// swipe, so it must never be something the frame waits on.
  void extend();
}

/// The one-item case — an avatar, a check-in snap, a single chat photo.
class SingleMediaSource extends MediaSource {
  SingleMediaSource(this.item);

  final MediaItem item;

  @override
  int get length => 1;

  @override
  MediaItem itemAt(int index) => item;

  @override
  void extend() {}
}
