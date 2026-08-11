import 'dart:async';
import 'dart:collection';

import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/media_source.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// Fetches one page of rows older than [beforeSeq]; null asks for the newest.
typedef SharedMediaFetch = Future<List<Message>> Function(int? beforeSeq);

/// The loaded window of one shelf, owned above both the grid and the pager.
///
/// There is exactly one of these per tab and both views read it. Two copies is
/// the version of this that looks fine and is broken in both directions: the
/// pager cannot swipe past the thirty rows the grid happened to have, and the
/// grid comes back thirty tiles tall after the pager loaded three hundred —
/// with no tile under the photo you were just looking at, so nothing to fly
/// home to and no scroll position that means anything.
class SharedMediaWindow extends MediaSource {
  SharedMediaWindow({
    required SharedMediaFetch fetch,
    required this.pageSize,
    required String partnerName,
    required String? myUid,
  })  : _fetch = fetch,
        _partnerName = partnerName,
        _myUid = myUid;

  final SharedMediaFetch _fetch;

  /// A short page is the end of the shelf. Has to match what [_fetch] limits
  /// to, or the window either stops early or asks forever.
  final int pageSize;

  /// Half of any shelf is the user's own sends, and "Photo from <partner>" on
  /// a photo you took yourself is a bug this screen inherited once already.
  final String _partnerName;
  final String? _myUid;

  final List<Message> _messages = [];
  final List<MediaItem> _media = [];
  bool _busy = false;
  bool _end = false;
  bool _loadedOnce = false;
  bool _failed = false;
  bool _disposed = false;

  /// Every row loaded, in shelf order. The Documents and Links shelves render
  /// from this; only the Media shelf has anything a pager can show.
  ///
  /// A view, not a copy: this is read from build(), and List.unmodifiable
  /// would copy every row of a five-thousand-row shelf on every frame.
  late final List<Message> messages = UnmodifiableListView(_messages);

  /// True once a first page has come back — a failed one included. Before
  /// that a shelf is loading, not empty.
  bool get loadedOnce => _loadedOnce;

  /// The last fetch threw. An empty shelf and a shelf that could not be read
  /// look identical, and telling a couple with four hundred photos that they
  /// have none is the app lying about their history because a request timed
  /// out.
  bool get failed => _failed;

  bool get hasMore => !_end;

  @override
  int get length => _media.length;

  @override
  MediaItem itemAt(int index) => _media[index];

  @override
  void extend() => unawaited(more());

  /// The next page, appended. Re-entrant calls are dropped rather than queued:
  /// the grid's scroll listener and the pager's look-ahead both call this, and
  /// they are frequently looking at the same gap.
  Future<void> more() async {
    if (_busy || _end) return;
    _busy = true;
    try {
      // The cursor is the last row's seq, never an offset: OFFSET 3000 makes
      // the server walk 3000 rows it then throws away, and shifts under any
      // message sent while the grid is open.
      final page = await _fetch(_messages.isEmpty ? null : _messages.last.seq);
      _messages.addAll(page);
      for (final m in page) {
        final item = _itemFor(m);
        if (item != null) _media.add(item);
      }
      _end = page.length < pageSize;
      _failed = false;
    } catch (_) {
      _failed = true;
    } finally {
      _busy = false;
      _loadedOnce = true;
      // Backing out of the profile while a page is in flight disposes this
      // before the request lands, and notifying then is an assertion failure
      // in debug — a crash for closing a screen too early.
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> retry() {
    _failed = false;
    notifyListeners();
    return more();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// A row a pager can show, or null for one it cannot — a video whose upload
  /// never landed a path, or a malformed image row. Dropping it here rather
  /// than at the tile is what keeps the pager's index and the grid's index the
  /// same number.
  MediaItem? _itemFor(Message m) {
    final sender = m.isMine(_myUid) ? 'you' : _partnerName;
    if (m.kind == 'video') {
      final path = m.videoPath;
      return path == null
          ? null
          : MediaItem.stored(intimateBucket, path,
              isVideo: true, senderName: sender, sentAt: m.createdAt,);
    }
    final path = m.imagePath;
    return path == null
        ? null
        : MediaItem.stored(chatBucket, path,
            senderName: sender, sentAt: m.createdAt,);
  }
}
