import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/media_album.dart';

/// Behaviour, executed. Grouping decides what the conversation LOOKS like —
/// twenty photos as one grid or as twenty full-width bubbles — and it is the
/// one piece of this that cannot be checked by reading a screen: the two
/// inputs it turns on (a stamped album_id, and a clock gap for everything
/// written before that column existed) never both appear in one screenshot.
void main() {
  // Newest first, which is the order the reversed ListView is fed.
  DateTime at(int secondsAgo) =>
      DateTime(2026, 8, 13, 12).subtract(Duration(seconds: secondsAgo));

  Message photo(
    String id, {
    required int secondsAgo,
    String sender = 'me',
    String? album,
    String kind = 'image',
    bool deleted = false,
  }) =>
      Message(
        id: id,
        senderId: sender,
        createdAt: at(secondsAgo),
        kind: kind,
        imagePath: 'couple/$id.jpg',
        albumId: album,
        deletedForEveryone: deleted,
      );

  Message text(String id, {required int secondsAgo}) => Message(
        id: id,
        senderId: 'me',
        createdAt: at(secondsAgo),
        body: 'hi',
      );

  group('album_id is authoritative', () {
    test('one pick is one row however long the upload spread it', () {
      // Three items of one pick, landing over four minutes — far outside any
      // time window. This is the case the stamp exists for.
      final rows = MediaAlbums.rows([
        photo('c', secondsAgo: 0, album: 'pick-1'),
        photo('b', secondsAgo: 120, album: 'pick-1'),
        photo('a', secondsAgo: 240, album: 'pick-1'),
      ]);

      expect(rows, hasLength(1));
      expect(rows.single.length, 3);
      expect(rows.single.isAlbum, isTrue);
    });

    test('two picks a second apart stay two rows', () {
      final rows = MediaAlbums.rows([
        photo('b', secondsAgo: 0, album: 'pick-2'),
        photo('a', secondsAgo: 1, album: 'pick-1'),
      ]);

      expect(rows, hasLength(2),
          reason: 'a clock cannot separate these; the stamp can',);
    });

    test('a stamped row never merges with an unstamped neighbour', () {
      final rows = MediaAlbums.rows([
        photo('b', secondsAgo: 0, album: 'pick-1'),
        photo('a', secondsAgo: 1),
      ]);

      expect(rows, hasLength(2));
    });
  });

  group('the time window covers what has no stamp', () {
    test('media from an old build inside the window is one row', () {
      final rows = MediaAlbums.rows([
        photo('c', secondsAgo: 0),
        photo('b', secondsAgo: 3),
        photo('a', secondsAgo: 6),
      ]);

      expect(rows.single.length, 3,
          reason: 'the history already in the table has to collapse too',);
    });

    test('a gap wider than the window starts a new row', () {
      final rows = MediaAlbums.rows([
        photo('b', secondsAgo: 0),
        photo('a', secondsAgo: 60),
      ]);

      expect(rows, hasLength(2));
    });

    test('the window is between neighbours, not across the whole run', () {
      // Each gap is 15s — inside the window — but the run spans 45s. A rule
      // written against the total span would break this into separate rows.
      final rows = MediaAlbums.rows([
        photo('d', secondsAgo: 0),
        photo('c', secondsAgo: 15),
        photo('b', secondsAgo: 30),
        photo('a', secondsAgo: 45),
      ]);

      expect(rows.single.length, 4);
    });
  });

  group('what may never be swept into an album', () {
    test('the other partner’s photo', () {
      final rows = MediaAlbums.rows([
        photo('b', secondsAgo: 0, sender: 'them'),
        photo('a', secondsAgo: 1),
      ]);

      expect(rows, hasLength(2));
    });

    test('a text message between two photos', () {
      final rows = MediaAlbums.rows([
        photo('c', secondsAgo: 0),
        text('b', secondsAgo: 1),
        photo('a', secondsAgo: 2),
      ]);

      expect(rows, hasLength(3),
          reason: 'grouping across it would reorder the conversation',);
    });

    test('a message deleted for everyone', () {
      final rows = MediaAlbums.rows([
        photo('c', secondsAgo: 0),
        photo('b', secondsAgo: 1, deleted: true),
        photo('a', secondsAgo: 2),
      ]);

      expect(rows, hasLength(3),
          reason: 'a tombstone still has to render as one',);
    });
  });

  test('a lone photo is not an album', () {
    final rows = MediaAlbums.rows([photo('a', secondsAgo: 0)]);

    expect(rows.single.isAlbum, isFalse,
        reason: 'a one-tile grid instead of the photo bubble',);
  });

  test('videos album with photos', () {
    final rows = MediaAlbums.rows([
      photo('b', secondsAgo: 0, kind: 'video', album: 'pick-1'),
      photo('a', secondsAgo: 2, album: 'pick-1'),
    ]);

    expect(rows.single.length, 2,
        reason: 'one pick takes both, so one row has to hold both',);
  });

  group('order within a row', () {
    test('tiles read oldest first, though the list runs newest first', () {
      final rows = MediaAlbums.rows([
        photo('third', secondsAgo: 0, album: 'p'),
        photo('second', secondsAgo: 2, album: 'p'),
        photo('first', secondsAgo: 4, album: 'p'),
      ]);

      expect([for (final m in rows.single.items) m.id],
          ['first', 'second', 'third'],
          reason: 'left in list order the grid shows the last photo top-left',);
    });

    test('the row sits where its newest item does, and begins at its oldest',
        () {
      final rows = MediaAlbums.rows([
        photo('third', secondsAgo: 0, album: 'p'),
        photo('first', secondsAgo: 4, album: 'p'),
      ]);

      expect(rows.single.newest.id, 'third');
      expect(rows.single.oldest.id, 'first');
    });
  });

  test('an empty conversation makes no rows', () {
    expect(MediaAlbums.rows([]), isEmpty);
  });
}
