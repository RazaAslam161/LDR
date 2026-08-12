import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/media_source.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/profile/shared_media_repository.dart';

/// Every photo and video in the conversation, as one thing to swipe through.
///
/// Tapping a photo in chat opened it and gave you nothing else: the viewer was
/// handed a single path, so a `SingleMediaSource` of length one, so there was
/// no next page to swipe to and no way out but Back. The pager, the preloading
/// and the zoom were all already built — chat just never gave them a set.
///
/// Ordered NEWEST FIRST, and paged the same way, which is what keeps an index
/// stable: [extend] appends older items off the end, so nothing the viewer is
/// currently showing shifts underneath it. Swiping forward walks backwards
/// through the conversation, the same direction scrolling up in chat does.
class ChatMediaSource extends MediaSource {
  ChatMediaSource({
    required this.coupleId,
    required List<Message> seed,
    required this.senderNameFor,
  }) : _items = List.of(seed);

  final String coupleId;

  /// Whose a given message is, for the label a save writes into the vault.
  final String Function(Message) senderNameFor;

  final List<Message> _items;

  /// Set once a page comes back short — there is nothing older to ask for and
  /// every further swipe would otherwise re-run the same query.
  bool _exhausted = false;
  bool _loading = false;

  /// Where [m] sits in this source, or 0 if it somehow is not in it.
  ///
  /// The viewer opens on an index, and the thing that was tapped is a message —
  /// matched by id rather than by position because the tile's position is
  /// within its album, not within the conversation's media.
  int indexOf(Message m) {
    final i = _items.indexWhere((x) => x.id == m.id);
    return i < 0 ? 0 : i;
  }

  @override
  int get length => _items.length;

  @override
  MediaItem itemAt(int index) {
    final m = _items[index];
    final isVideo = m.kind == 'video';
    final raw = isVideo ? m.videoPath : m.imagePath;
    return MediaItem.stored(
      isVideo ? intimateBucket : chatBucket,
      raw ?? '',
      isVideo: isVideo,
      senderName: senderNameFor(m),
      sentAt: m.createdAt,
    );
  }

  @override
  void extend() {
    if (_exhausted || _loading || _items.isEmpty) return;
    _loading = true;
    // Fire-and-forget on purpose: this is called from a swipe, and a frame that
    // waits on a network page is a frame that stutters.
    SharedMediaRepository.page(
      coupleId,
      SharedMediaKind.media,
      beforeSeq: _items.last.seq,
    ).then((older) {
      _loading = false;
      if (older.isEmpty) {
        _exhausted = true;
        return;
      }
      // The seed came from the chat's own list, which overlaps whatever the
      // first page returns. Without this the viewer shows the same photos twice
      // at the seam.
      final have = {for (final m in _items) m.id};
      final fresh = older.where((m) => !have.contains(m.id)).toList();
      if (fresh.isEmpty) {
        _exhausted = true;
        return;
      }
      _items.addAll(fresh);
      notifyListeners();
    }).catchError((Object _) {
      // A failed page is not a dead viewer — what is already loaded still
      // swipes, and the next swipe past the end tries again.
      _loading = false;
    });
  }
}
