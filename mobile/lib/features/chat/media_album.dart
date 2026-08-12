import 'package:miles/features/chat/chat_repository.dart';

/// One row of the conversation: either a single message, or a run of media that
/// was sent together and draws as one grid.
///
/// The list used to be a flat list of messages, which is why twenty photos were
/// twenty full-width bubbles and a mile of scrolling. A row is the unit the
/// ListView builds now.
class ChatRow {
  const ChatRow(this.items);

  /// OLDEST first — the order they were picked, which is the order a grid has
  /// to read in. The conversation around it runs the other way (newest first,
  /// for the reversed ListView), so this is deliberately not the list's order:
  /// left in it, a pick of twenty would show the twentieth photo top-left.
  final List<Message> items;

  /// The newest message in the row. Reply, receipts and send status answer to
  /// this — an album is one thing in the conversation, and it sits where its
  /// last item does.
  Message get newest => items.last;

  /// The oldest, which is where the row begins and so what a date header marks.
  Message get oldest => items.first;

  bool get isAlbum => items.length > 1;

  int get length => items.length;
}

/// How the conversation's flat message list becomes rows.
class MediaAlbums {
  MediaAlbums._();

  /// The longest gap between two consecutive items that can still be one send.
  ///
  /// Only consulted for rows with no album_id — see [_sameAlbum]. This is the
  /// gap between NEIGHBOURS, not the span of the whole group, so a pick of
  /// forty photos uploading three at a time stays one album however long the
  /// batch takes overall, while the next thing typed a minute later starts a
  /// new row.
  static const _window = Duration(seconds: 20);

  /// Collapse runs of together-sent media into single rows.
  ///
  /// [messages] is in display order — newest first, the order the reversed
  /// ListView wants.
  static List<ChatRow> rows(List<Message> messages) {
    final out = <ChatRow>[];
    var i = 0;
    while (i < messages.length) {
      final start = messages[i];
      if (!_isMedia(start)) {
        out.add(ChatRow([start]));
        i++;
        continue;
      }
      var j = i + 1;
      while (j < messages.length && _sameAlbum(messages[j - 1], messages[j])) {
        j++;
      }
      // Reversed on the way in: the run was walked newest-first because that is
      // how the conversation is ordered, and a grid reads oldest-first.
      out.add(ChatRow(messages.sublist(i, j).reversed.toList()));
      i = j;
    }
    return out;
  }

  static bool _isMedia(Message m) =>
      (m.kind == 'image' || m.kind == 'video') && !m.deletedForEveryone;

  /// Whether [b] continues the album [a] belongs to.
  ///
  /// Two rows stamped with the same album_id are one send and that is the end
  /// of it. Two rows stamped differently are two sends, however close together
  /// — which is the case a clock can never get right.
  ///
  /// The time window is only reached when NEITHER row carries a stamp, and that
  /// is not a transitional state: this fleet is sideloaded with no update
  /// channel, so builds that predate album_id keep sending unstamped media
  /// indefinitely, on top of the history already in the table.
  ///
  /// It does mean two photos sent deliberately a few seconds apart from an old
  /// build merge into one row. That is accepted rather than worked around —
  /// compacting a column of full-width photos into a grid is the entire point
  /// of this, and two tiles side by side is the better of the two readings.
  static bool _sameAlbum(Message a, Message b) {
    if (!_isMedia(a) || !_isMedia(b)) return false;
    if (a.senderId != b.senderId) return false;

    final albumA = a.albumId;
    final albumB = b.albumId;
    if (albumA != null || albumB != null) return albumA == albumB;

    return a.createdAt.difference(b.createdAt).abs() <= _window;
  }
}
