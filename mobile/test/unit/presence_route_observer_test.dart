import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/presence_route_observer.dart';
import 'package:miles/core/screen_presence.dart';

/// Presence drives what one partner believes the other is doing. A wrong value
/// is worse than no value, so these pin the mapping that decides it.
void main() {
  group('screenNameForPath', () {
    test('names the screen from the deepest path segment', () {
      expect(screenNameForPath('/app/touch'), 'Touch');
      expect(screenNameForPath('/app/cycle'), 'Cycle');
      expect(screenNameForPath('/app/heartbeat'), 'Heartbeat');
      expect(screenNameForPath('/app/timeline'), 'Timeline');
    });

    test('humanises hyphenated segments', () {
      expect(screenNameForPath('/app/closer/body-map'), 'Body Map');
      expect(screenNameForPath('/app/closer/memory-threads'), 'Memory Threads');
      expect(screenNameForPath('/app/games/truth-dare'), 'Truth Dare');
      expect(screenNameForPath('/app/location-map'), 'Location Map');
    });

    test('reports nothing for places that are not a room', () {
      // Auth screens and the capture camera are not somewhere a partner is
      // "in", and announcing them would be noise at best and confusing at
      // worst.
      for (final p in [
        '/',
        '/signin',
        '/signup',
        '/welcome',
        '/couple',
        '/role-setup',
        '/app/rapid-camera',
      ]) {
        expect(screenNameForPath(p), isNull, reason: '$p should not report');
      }
    });

    test('the tab shell defers to AppShell', () {
      // '/app' is the container; WHICH tab you are on is known only to
      // AppShell. Reporting "App" here would overwrite the real tab name.
      expect(screenNameForPath('/app'), isNull);
    });

    test('every real route in the app produces a name', () {
      // The original bug: only 13 of 44 routes ever reported, so walking into
      // one of the other 31 left the partner seeing where you were last.
      const realRoutes = [
        '/app/settings', '/app/disguise', '/app/capsule', '/app/capsule/new',
        '/app/intimacy', '/app/vault', '/app/touch', '/app/together',
        '/app/reasons', '/app/care', '/app/watch', '/app/cycle',
        '/app/heartbeat', '/app/games', '/app/rituals', '/app/prompt',
        '/app/timeline', '/app/location-map', '/app/closer/touch-trace',
        '/app/closer/mood-lamp', '/app/closer/desire', '/app/closer/vault',
        '/app/closer/afterglow', '/app/closer/fantasy-jar',
        '/app/closer/body-map', '/app/closer/pick-for-us', '/call',
      ];
      for (final r in realRoutes) {
        final name = screenNameForPath(r);
        expect(name, isNotNull, reason: '$r would leave presence stale');
        expect(name, isNotEmpty);
      }
    });
  });

  group('joining them', () {
    test('every joinable route round-trips back to its own name', () {
      // The tap target is derived from the name the partner published, so if
      // the two tables ever disagree the user lands on the wrong screen — or on
      // a path that does not exist, which throws.
      kJoinableRoutes.forEach((name, path) {
        expect(screenNameForPath(path), name,
            reason: '$name -> $path does not name itself back');
      });
    });

    test('private rooms are never joinable', () {
      // Following someone into the vault would betray the one place in the app
      // that is meant to be theirs alone. Settings and the disguise picker are
      // equally not invitations, and a live call is not a room you walk into.
      for (final private in [
        'Vault',
        'Settings',
        'Disguise',
        'Call',
        'Desire',
        'Prefs',
      ]) {
        expect(joinableRouteFor(private), isNull, reason: '$private is private');
        expect(joinableTabIndex(private), isNull, reason: '$private is private');
      }
    });

    test('a screen nobody published is not joinable', () {
      expect(joinableRouteFor(null), isNull);
      expect(joinableTabIndex(null), isNull);
      expect(joinableRouteFor('Some Future Screen'), isNull);
    });

    test('tab screens join by index, not by route', () {
      // They live inside the shell, so pushing '/app/chat' would 404.
      expect(joinableTabIndex('Chat'), 1);
      expect(joinableRouteFor('Chat'), isNull);
      // Index 2 is the camera button — a capture action, not a room.
      expect(kJoinableTabs.values, isNot(contains(2)));
    });

    test('tab indices match the bottom nav', () {
      // Two hand-written tables pointing at the same tabs: if someone reorders
      // the nav, joining "Chat" would silently open Breath.
      kJoinableTabs.forEach((name, index) {
        expect(kTabScreens[index], name,
            reason: 'tab $index is ${kTabScreens[index]}, not $name');
      });
    });
  });
}
