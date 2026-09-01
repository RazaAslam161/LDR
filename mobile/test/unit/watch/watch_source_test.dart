import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/watch/watch_source.dart';

void main() {
  group('YouTube shapes the old convertUrlToId rejected', () {
    const id = 'dQw4w9WgXcQ';
    final accepted = <String, String>{
      'plain watch': 'https://www.youtube.com/watch?v=$id',
      'short host': 'https://youtu.be/$id',
      'short host with si': 'https://youtu.be/$id?si=AbCdEf',
      'shorts': 'https://www.youtube.com/shorts/$id',
      'live': 'https://www.youtube.com/live/$id',
      'embed': 'https://www.youtube.com/embed/$id',
      'mobile': 'https://m.youtube.com/watch?v=$id',
      'no scheme': 'www.youtube.com/watch?v=$id',
      'nocookie': 'https://www.youtube-nocookie.com/embed/$id',
      // v is NOT the first query param — the old regex required that it be.
      'list before v': 'https://www.youtube.com/watch?list=PL123&v=$id',
      'text around it': 'look at this https://youtu.be/$id lol',
      'trailing punctuation': 'watch https://youtu.be/$id.',
      'html escaped': 'https://www.youtube.com/watch?v=$id&amp;feature=share',
      'bare id': id,
    };

    accepted.forEach((name, url) {
      test(name, () {
        final s = resolveWatchLink(url);
        expect(s, isNotNull, reason: '$url resolved to null');
        expect(s!.kind, WatchKind.youtube);
        expect(s.key, id);
      });
    });
  });

  group('timestamps', () {
    const id = 'dQw4w9WgXcQ';
    final cases = <String, Duration>{
      't=90': const Duration(seconds: 90),
      't=90s': const Duration(seconds: 90),
      't=1m30s': const Duration(seconds: 90),
      't=1h2m3s': const Duration(hours: 1, minutes: 2, seconds: 3),
      'start=45': const Duration(seconds: 45),
    };
    cases.forEach((q, want) {
      test(q, () {
        final s = resolveWatchLink('https://youtu.be/$id?$q');
        expect(s!.startAt, want);
      });
    });

    test('1:30 and 1:02:03 colon forms', () {
      expect(parseTimestamp('1:30'), const Duration(seconds: 90));
      expect(parseTimestamp('1:02:03'),
          const Duration(hours: 1, minutes: 2, seconds: 3));
    });

    test('nonsense is zero, not a crash', () {
      expect(parseTimestamp('banana'), Duration.zero);
      expect(parseTimestamp(''), Duration.zero);
      expect(parseTimestamp(null), Duration.zero);
    });
  });

  group('direct media', () {
    test('mp4 is playable inline', () {
      final s = resolveWatchLink('https://example.com/clip.mp4')!;
      expect(s.kind, WatchKind.media);
      expect(s.format, MediaFormat.other);
    });

    test('m3u8 is tagged hls so the demuxer is chosen correctly', () {
      final s = resolveWatchLink('https://example.com/live/stream.m3u8')!;
      expect(s.kind, WatchKind.media);
      expect(s.format, MediaFormat.hls);
    });

    test('mpd is tagged dash', () {
      expect(resolveWatchLink('https://e.com/v.mpd')!.format, MediaFormat.dash);
    });

    test('query string does not hide the extension', () {
      final s = resolveWatchLink('https://e.com/clip.mp4?token=abc123')!;
      expect(s.kind, WatchKind.media);
    });

    test('http media is refused with a reason, not silently retried', () {
      final s = resolveWatchLink('http://example.com/clip.mp4')!;
      expect(s.kind, WatchKind.blocked);
      expect(s.reason, contains('unencrypted'));
    });
  });

  group('sites that cannot be embedded', () {
    test('DRM is named as impossible rather than failing oddly', () {
      final s = resolveWatchLink('https://www.netflix.com/watch/80100172')!;
      expect(s.kind, WatchKind.blocked);
      expect(s.site, 'Netflix');
      expect(s.reason, contains('DRM'));
    });

    test('Vimeo is driven inline, not handed to the browser', () {
      final s = resolveWatchLink('https://vimeo.com/123456789')!;
      expect(s.kind, WatchKind.embed);
      expect(s.site, 'Vimeo');
      // The SHARE url on the wire, the player id beside it — a bare id as the
      // key reopens on the partner's phone as nothing at all.
      expect(s.key, 'https://vimeo.com/123456789');
      expect(s.embedId, '123456789');
    });

    test('TikTok is driven inline', () {
      final s = resolveWatchLink(
        'https://www.tiktok.com/@someone/video/7212345678901234567',
      )!;
      expect(s.kind, WatchKind.embed);
      expect(s.site, 'TikTok');
      expect(s.embedId, '7212345678901234567');
    });

    test('a TikTok link with no video id in it opens in-app instead', () {
      // vm.tiktok.com short links need a redirect resolved, and resolving one
      // is a network call this function is not allowed to make.
      final s = resolveWatchLink('https://vm.tiktok.com/ZMabcdefg/')!;
      expect(s.kind, WatchKind.cobrowse);
    });

    test('a Vimeo profile link is not mistaken for a video', () {
      final s = resolveWatchLink('https://vimeo.com/someuser')!;
      expect(s.kind, WatchKind.cobrowse);
    });

    test('X opens in-app, with no claim that it is in sync', () {
      final s = resolveWatchLink('https://x.com/someone/status/1234567890')!;
      expect(s.kind, WatchKind.cobrowse);
      expect(s.site, 'X');
    });

    test('a YouTube playlist with no video opens in-app', () {
      final s = resolveWatchLink('https://www.youtube.com/playlist?list=PL12')!;
      expect(s.kind, WatchKind.cobrowse);
      expect(s.reason, contains('playlist'));
    });

    test('an unknown site still opens rather than being called invalid', () {
      final s = resolveWatchLink('https://some-blog.example/post/1')!;
      expect(s.kind, WatchKind.cobrowse);
      expect(s.site, isNotNull);
    });
  });

  group('rewrites that turn a share link into a media link', () {
    test('dropbox dl=0 becomes raw=1', () {
      final s = resolveWatchLink('https://www.dropbox.com/s/x/v.mp4?dl=0')!;
      expect(s.kind, WatchKind.media);
      expect(s.key, contains('raw=1'));
      expect(s.key, isNot(contains('dl=0')));
    });
  });

  _roundTripTests();

  group('not links', () {
    for (final junk in ['', '   ', 'hello there', '12345']) {
      test('${junk.isEmpty ? '(empty)' : junk} resolves to null', () {
        expect(resolveWatchLink(junk), isNull);
      });
    }
  });
}

// The wire carries only a key, so the partner's phone must be able to tell a
// YouTube id from a media URL with nothing else to go on. If this round-trip
// breaks, one side opens a player the other is not driving.
void _roundTripTests() {
  group('sourceFromKey round-trips what the wire carries', () {
    test('an 11-char id reopens as YouTube', () {
      final s = sourceFromKey('dQw4w9WgXcQ')!;
      expect(s.kind, WatchKind.youtube);
      expect(s.key, 'dQw4w9WgXcQ');
    });

    test('an embed key reopens as the same embed, with its player id', () {
      // The partner receives only the key. If it does not come back as embed
      // with an id, their phone shows nothing while ours plays.
      final sent = resolveWatchLink('https://vimeo.com/123456789')!;
      final got = sourceFromKey(sent.key)!;
      expect(got.kind, WatchKind.embed);
      expect(got.site, 'Vimeo');
      expect(got.embedId, sent.embedId);
    });

    test('an mp4 URL reopens as media, keeping its format hint', () {
      final s = sourceFromKey('https://example.com/clip.mp4')!;
      expect(s.kind, WatchKind.media);
      expect(s.format, MediaFormat.other);
    });

    test('an m3u8 URL reopens as HLS media', () {
      final s = sourceFromKey('https://example.com/s.m3u8')!;
      expect(s.kind, WatchKind.media);
      expect(s.format, MediaFormat.hls);
    });

    test('a start offset survives the trip', () {
      final s = sourceFromKey(
        'https://example.com/clip.mp4',
        startAt: const Duration(seconds: 42),
      )!;
      expect(s.startAt, const Duration(seconds: 42));
    });

    test('every resolved key reopens as the same kind it was', () {
      for (final url in [
        'https://youtu.be/dQw4w9WgXcQ',
        'https://example.com/clip.mp4',
        'https://example.com/s.m3u8',
        'https://vimeo.com/123456789',
      ]) {
        final first = resolveWatchLink(url)!;
        final again = sourceFromKey(first.key)!;
        expect(again.kind, first.kind, reason: url);
        expect(again.key, first.key, reason: url);
      }
    });
  });
}
