import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/watch/watch_viewer.dart';

/// The in-app viewer exists so that a link does not end the evening by throwing
/// both of you into another app. Every site it shows would rather you were in
/// its app, and they all reach for the same exits: an `intent://` deep link, a
/// custom scheme, or a plain https redirect to the Play Store — fired from the
/// player controls, the scrubber, or fullscreen.
///
/// Pasting an X link, tapping skip or fullscreen, and landing on the Play Store
/// listing for X is exactly what these refuse.
void main() {
  const x = 'x.com';

  group('the ways out are refused', () {
    test('an Android intent:// handoff', () {
      expect(
        staysInViewer(
          Uri.parse('intent://x.com/i/status/1#Intent;package=com.twitter.android;end'),
          origin: x,
        ),
        isFalse,
      );
    });

    test('a custom app scheme', () {
      for (final u in [
        'twitter://status?id=1',
        'tiktok://video/1',
        'fb://video/1',
        'instagram://media?id=1',
        'vnd.youtube://abc',
      ]) {
        expect(staysInViewer(Uri.parse(u), origin: x), isFalse, reason: u);
      }
    });

    test('the https spelling of a store listing', () {
      expect(
        staysInViewer(
          Uri.parse('https://play.google.com/store/apps/details?id=com.twitter.android'),
          origin: x,
        ),
        isFalse,
      );
      expect(
        staysInViewer(Uri.parse('https://apps.apple.com/app/id333903271'), origin: x),
        isFalse,
      );
    });

    test('a market:// link', () {
      expect(
        staysInViewer(Uri.parse('market://details?id=com.twitter.android'), origin: x),
        isFalse,
      );
    });

    test('a null url', () {
      expect(staysInViewer(null, origin: x), isFalse);
    });
  });

  group('ordinary browsing is still allowed', () {
    test('staying on the site', () {
      expect(
        staysInViewer(Uri.parse('https://x.com/someone/status/2'), origin: x),
        isTrue,
      );
    });

    test('a normal link off the page', () {
      expect(
        staysInViewer(Uri.parse('https://example.com/article'), origin: x),
        isTrue,
      );
    });

    test('the CDN the video actually streams from', () {
      expect(
        staysInViewer(Uri.parse('https://video.twimg.com/a.m3u8'), origin: x),
        isTrue,
      );
    });
  });

  test('a store link is allowed when the store IS what was pasted', () {
    // Odd thing to watch together, but refusing to load the very page the user
    // chose would be the viewer breaking its own promise.
    expect(
      staysInViewer(
        Uri.parse('https://play.google.com/store/apps/details?id=a'),
        origin: 'play.google.com',
      ),
      isTrue,
    );
  });
}
