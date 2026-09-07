import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/watch/watch_embed.dart';
import 'package:miles/features/watch/watch_source.dart';

/// The embed layer is two halves that have to agree: watch_source decides a
/// link is [WatchKind.embed] and names a site, and watch_embed has to have an
/// adapter for that name. Nothing in the type system connects them — a host
/// added to one and not the other compiles, then throws on the null assertion
/// in the screen when someone finally pastes that link.
void main() {
  group('every embed site has an adapter', () {
    // The links watch_source is expected to classify as embed.
    const links = {
      'Vimeo': 'https://vimeo.com/123456789',
      'TikTok': 'https://www.tiktok.com/@someone/video/7212345678901234567',
    };

    for (final e in links.entries) {
      test('${e.key} resolves to an adapter', () {
        final s = resolveWatchLink(e.value)!;
        expect(s.kind, WatchKind.embed, reason: '${e.key} stopped embedding');
        expect(s.site, e.key);
        expect(
          adapterFor(s.site!),
          isNotNull,
          reason: '${e.key} is an embed site with no adapter — the screen '
              'asserts non-null on this and would throw',
        );
        // The player asserts non-null on this too.
        expect(s.embedId, isNotNull);
      });
    }

    test('a site with no adapter returns null rather than a wrong one', () {
      expect(adapterFor('Instagram'), isNull);
      expect(adapterFor(''), isNull);
    });
  });

  group('player URLs', () {
    test('Vimeo asks not to be tracked and does not autoplay', () {
      final url = adapterFor('Vimeo')!.playerUrl('123456789', Duration.zero);
      expect(url.host, 'player.vimeo.com');
      expect(url.query, contains('dnt=1'));
      expect(url.query, contains('autoplay=0'));
    });

    test('Vimeo carries a start time as a fragment', () {
      final url =
          adapterFor('Vimeo')!.playerUrl('1', const Duration(seconds: 90));
      expect(url.fragment, 't=90s');
    });

    test('TikTok addresses the v1 player by post id', () {
      final url = adapterFor('TikTok')!
          .playerUrl('7212345678901234567', Duration.zero);
      expect(url.host, 'www.tiktok.com');
      expect(url.path, '/player/v1/7212345678901234567');
      expect(url.query, contains('autoplay=0'));
    });

    test('TikTok carries a start time as a query parameter', () {
      final url =
          adapterFor('TikTok')!.playerUrl('1', const Duration(seconds: 30));
      expect(url.queryParameters['timestamp'], '30');
    });
  });

  group('the JS bridge', () {
    for (final site in ['Vimeo', 'TikTok']) {
      test('$site reports back on the handler the player listens to', () {
        final a = adapterFor(site)!;
        // The Dart side registers exactly one handler name; a bridge that
        // calls anything else is silently inert.
        expect(a.bridge, contains("callHandler('watch'"));
        // Every command drives the same handle the bridge installs.
        expect(a.play, contains('window.__w'));
        expect(a.pause, contains('window.__w'));
        expect(a.seek(const Duration(seconds: 5)), contains('window.__w'));
      });

      test('$site seeks in seconds, not milliseconds', () {
        final js = adapterFor(site)!.seek(const Duration(milliseconds: 1500));
        expect(js, contains('1.5'));
      });
    }
  });

  group('the host page', () {
    test('is served from a real origin, because postMessage needs one', () {
      final a = adapterFor('Vimeo')!;
      expect(a.origin, startsWith('https://'));
      final html = embedHtml(a, a.playerUrl('1', Duration.zero));
      expect(html, contains('player.vimeo.com/api/player.js'));
      expect(html, contains('<iframe'));
    });

    test('does not load the Vimeo SDK for TikTok', () {
      final a = adapterFor('TikTok')!;
      final html = embedHtml(a, a.playerUrl('1', Duration.zero));
      expect(html, isNot(contains('vimeo')));
    });
  });

  test('the empty state does not promise sync for links the code opens solo',
      () {
    // WatchKind.cobrowse never reaches _openSource: 'Watch here' is a local
    // viewer with no row and no broadcast. The screen doc and the empty state
    // were written before that branch existed and promised sync for any link.
    final screen =
        File('lib/features/watch/watch_together_screen.dart').readAsStringSync();
    final at = screen.indexOf('watch it in sync');
    expect(at, greaterThan(0));
    expect(screen.substring(at, at + 200), contains('your phone only'));
    final doc = screen.split('\n').take(40).join('\n');
    expect(doc, isNot(contains('on both phones')));
  });
}
