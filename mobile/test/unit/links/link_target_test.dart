import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/links/link_scan.dart';
import 'package:miles/core/links/link_target.dart';

void main() {
  group('classification', () {
    test('a reel is a Reel, and its shortcode survives', () {
      final t = classifyLink('https://www.instagram.com/reel/C8xYz_Ab1/');
      expect(t.provider, LinkProvider.instagram);
      expect(t.label, 'Reel');
      expect(t.id, 'C8xYz_Ab1');
    });

    test('a youtube short is told apart from a video', () {
      expect(classifyLink('https://youtube.com/shorts/abc123XYZ').label,
          'Short',);
      expect(classifyLink('https://www.youtube.com/watch?v=abc123XYZ').label,
          'Video',);
    });

    test('youtu.be and watch?v= reach the same id', () {
      expect(classifyLink('https://youtu.be/dQw4w9WgXcQ').id, 'dQw4w9WgXcQ');
      expect(
          classifyLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ').id,
          'dQw4w9WgXcQ',);
    });

    test('a tiktok shortlink is a tiktok with no id yet', () {
      final t = classifyLink('https://vm.tiktok.com/ZMabcdef/');
      expect(t.provider, LinkProvider.tiktok);
      expect(t.id, isNull, reason: 'the id is behind a redirect');
    });

    test('an unrecognised link is still a link', () {
      final t = classifyLink('https://example.com/a/b');
      expect(t.provider, LinkProvider.generic);
      expect(t.site, 'example.com');
    });
  });

  group('canonicalise', () {
    test('per-share tokens are stripped', () {
      // igshid and si identify the ACCOUNT that generated the share. Leaving
      // them in hands a third party that identity, and splits the cache.
      final t = classifyLink(
          'https://www.instagram.com/reel/C8xYz_Ab1/?igshid=abc123&utm_source=x',);
      expect(t.canonical, isNot(contains('igshid')));
      expect(t.canonical, isNot(contains('utm_source')));
      expect(t.canonical, contains('C8xYz_Ab1'));
    });

    test('two shares of one reel canonicalise to one string', () {
      final a = classifyLink(
          'https://www.instagram.com/reel/C8xYz_Ab1/?igshid=AAA',);
      final b = classifyLink(
          'https://www.instagram.com/reel/C8xYz_Ab1/?igshid=BBB',);
      expect(a.canonical, b.canonical);
    });

    test('a real query parameter is kept', () {
      final t = classifyLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42');
      expect(t.canonical, contains('v=dQw4w9WgXcQ'));
      expect(t.canonical, contains('t=42'));
    });

    test('music.youtube.com becomes the plain host', () {
      final t = classifyLink('https://music.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(t.canonical, contains('www.youtube.com'));
      expect(t.provider, LinkProvider.youtube);
    });
  });

  group('scanning', () {
    test('a sentence-ending full stop is not part of the URL', () {
      final s = LinkScan.spans('look at https://example.com/a.');
      expect(s.single.url, 'https://example.com/a');
    });

    test('a bracket the URL opened is kept', () {
      final s = LinkScan.spans('https://en.wikipedia.org/wiki/A_(b)');
      expect(s.single.url, 'https://en.wikipedia.org/wiki/A_(b)');
    });

    test('a bracket the sentence opened is not', () {
      final s = LinkScan.spans('(see https://example.com/a)');
      expect(s.single.url, 'https://example.com/a');
    });

    test('a bare www gets a scheme so the tap can do something', () {
      final s = LinkScan.spans('www.example.com');
      expect(s.single.url, 'https://www.example.com');
    });

    test('several links in one message are all found, in order', () {
      final s = LinkScan.spans(
          'https://a.com then https://b.com and https://c.com',);
      expect(s.map((e) => e.url).toList(),
          ['https://a.com', 'https://b.com', 'https://c.com'],);
    });

    test('a body with no link scans to nothing', () {
      expect(LinkScan.spans('just words'), isEmpty);
      expect(LinkScan.spans(null), isEmpty);
      expect(LinkScan.spans(''), isEmpty);
    });

    test('spans index the original body exactly', () {
      const body = 'go to https://x.com now';
      final s = LinkScan.spans(body).single;
      expect(body.substring(s.start, s.end), 'https://x.com');
    });
  });
}
