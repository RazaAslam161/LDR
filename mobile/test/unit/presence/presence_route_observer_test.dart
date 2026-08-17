import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/realtime/presence_route_observer.dart';
import 'package:miles/core/realtime/screen_presence.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// Presence drives what one partner believes the other is doing. A wrong value
/// is worse than no value, so these pin the mapping that decides it.
void main() {
  // The observer asks SchedulerBinding which phase it is in before writing.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('screenNameForPath', () {
    test('names the screen from the deepest path segment', () {
      expect(screenNameForPath('/app/touch'), 'Touch');
      expect(screenNameForPath('/app/cycle'), 'Cycle');
      expect(screenNameForPath('/app/heartbeat'), 'Heartbeat');
      expect(screenNameForPath('/app/timeline'), 'Timeline');
    });

    test('humanises hyphenated segments', () {
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
        '/offline',
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
        '/app/mood-signal', '/app/vault', '/app/touch',
        '/app/reasons', '/app/care', '/app/watch', '/app/cycle',
        '/app/heartbeat', '/app/games', '/app/rituals', '/app/prompt',
        '/app/timeline', '/app/location-map', '/app/closer/touch-trace',
        '/app/closer/mood-lamp', '/app/closer/warmth', '/app/closer/vault',
        '/app/closer/wish-jar', '/app/closer/pick-for-us',
      ];
      for (final r in realRoutes) {
        final name = screenNameForPath(r);
        expect(name, isNotNull, reason: '$r would leave presence stale');
        expect(name, isNotEmpty);
      }
    });

    test('a call is not a room — it publishes nothing', () {
      // This test used to require the opposite: '/call' sat in the list above,
      // pinning a presence oracle in place. Publishing it told the partner "In
      // Call" on Home, from BOTH sides — the caller before the offer was even
      // sent, and the callee before they had accepted or declined, so declining
      // still announced that the ring had been seen. A call attempt must not
      // create presence information about either party.
      expect(screenNameForPath('/call'), isNull);
    });
  });

  group('joining them', () {
    test('every joinable route round-trips back to its own name', () {
      // The tap target is derived from the name the partner published, so if
      // the two tables ever disagree the user lands on the wrong screen — or on
      // a path that does not exist, which throws.
      kJoinableRoutes.forEach((name, path) {
        expect(screenNameForPath(path), name,
            reason: '$name -> $path does not name itself back',);
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
        expect(joinableTabIndex(private, showTouch: true), isNull, reason: '$private is private');
      }
    });

    test('a screen nobody published is not joinable', () {
      expect(joinableRouteFor(null), isNull);
      expect(joinableTabIndex(null, showTouch: true), isNull);
      expect(joinableRouteFor('Some Future Screen'), isNull);
    });

    test('tab screens join by index, not by route', () {
      // They live inside the shell, so pushing '/app/chat' would 404.
      expect(joinableTabIndex('Chat', showTouch: true), 1);
      expect(joinableRouteFor('Chat'), isNull);
      // Index 2 is the camera button — a capture action, not a room.
      for (final showTouch in [true, false]) {
        expect(joinableTabs(showTouch: showTouch).values, isNot(contains(2)),
            reason: 'camera is joinable with showTouch: $showTouch',);
      }
    });

    test('tab indices match the bottom nav in BOTH shapes', () {
      // Touch sits in the middle and disappears with modest mode, sliding
      // Closer down one. A fixed table landed on the right tab only because the
      // shell clamps an out-of-range index — so this walks both shapes.
      for (final showTouch in [true, false]) {
        final visible = visibleTabScreens(showTouch: showTouch);
        joinableTabs(showTouch: showTouch).forEach((name, index) {
          expect(visible[index], name,
              reason: 'showTouch: $showTouch — tab $index is ${visible[index]}, '
                  'not $name',);
        });
      }
    });

    test('Touch is unjoinable exactly when it is not on the bar', () {
      expect(joinableTabs(showTouch: true).containsKey('Touch'), isTrue);
      expect(joinableTabs(showTouch: false).containsKey('Touch'), isFalse,
          reason: 'joining a tab that is not rendered lands on another one',);
    });
  });

  group('what the observer treats as a move', () {
    /// The observer talks to Supabase through providers; with a null couple it
    /// publishes nothing, so the local value is what we can watch.
    (PresenceRouteObserver, ProviderContainer) build() {
      // Null couple: _publish still sets the local value but never reaches
      // Supabase, which is not running here.
      final c = ProviderContainer(
        overrides: [currentCoupleProvider.overrideWithValue(null)],
      );
      addTearDown(c.dispose);
      return (PresenceRouteObserver(_ContainerRef(c)), c);
    }

    Route<dynamic> page(String? name) => MaterialPageRoute<void>(
          settings: RouteSettings(name: name),
          builder: (_) => const SizedBox.shrink(),
        );

    test('a couple-less publish does not suppress the real one', () {
      // The presence bug, as the field trace showed it. With no couple the
      // publish reaches nobody — but it recorded itself as the current screen
      // anyway, so when the couple arrived the SAME room was deduped and never
      // written. The partner could not see where you were until you navigated
      // somewhere else, which on a phone left open on one screen is never.
      //
      // Two full audits refuted every candidate. It took a trace:
      //   has_couple:false wrote_db:false   (twice)
      //   deduped:true     wrote_db:false   (once the couple returned)
      //
      // Asserted on the trace rather than on myScreenProvider, because the
      // local value is 'Touch' either way — that is precisely what made the
      // bug invisible, and a test that watched it would be too.
      Diag.resetForTest();
      final (obs, _) = build();

      obs.didPush(page('/app/touch'), null);
      obs.didPush(page('/app/touch'), null);

      final publishes = Diag.recent
          .where((e) => e.name == 'presence_screen_publish')
          .toList();
      expect(publishes.length, greaterThanOrEqualTo(2),
          reason: 'the observer stopped recording publishes',);

      // The old behaviour: the second one came back deduped, so the write was
      // suppressed for a room that had never been written.
      final deduped =
          publishes.where((e) => e.fields['deduped'] == true).toList();
      expect(deduped, isEmpty,
          reason: 'a room that never reached the database was treated as '
              'already published: ${deduped.map((e) => e.fields)}',);

      // And it is held for replay rather than dropped.
      expect(publishes.any((e) => e.fields['deferred'] == true), isTrue,
          reason: 'the couple-less publish was discarded, not deferred',);
    });

    test('a named page publishes its room', () {
      final (obs, c) = build();
      obs.didPush(page('/app/touch'), null);
      expect(c.read(myScreenProvider), 'Touch');
    });

    test('an UNNAMED page says "somewhere", not the last room', () {
      // Eleven places still push a bare MaterialPageRoute. Leaving the previous
      // screen published is how the app ends up insisting she is still in the
      // chat while she is looking at a map.
      final (obs, c) = build();
      obs.didPush(page('/app/touch'), null);
      obs.didPush(page(null), null);
      expect(c.read(myScreenProvider), isNull);
    });

    test('a dialog or sheet is not a move', () {
      // They sit on top of a room rather than being one — vanishing from Touch
      // because a confirm dialog opened would be a lie in the other direction.
      final (obs, c) = build();
      obs.didPush(page('/app/touch'), null);
      obs.didPush(
        RawDialogRoute<void>(
          pageBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
        null,
      );
      expect(c.read(myScreenProvider), 'Touch');
    });

    test('popping back republishes the room underneath', () {
      final (obs, c) = build();
      obs.didPush(page('/app/touch'), null);
      obs.didPush(page(null), null);
      obs.didPop(page(null), page('/app/touch'));
      expect(c.read(myScreenProvider), 'Touch');
    });

    test('an unnamed page opened from a TAB stops claiming the tab', () {
      // The case that actually happens: you are on the Home tab and open the
      // 3D map, which is a bare MaterialPageRoute. Going on saying "Home" put
      // the partner's avatar on the map glowing "here with you".
      final (obs, c) = build();
      obs.didPush(page('/app'), null); // the shell → the selected tab
      expect(c.read(myScreenProvider), 'Home');
      obs.didPush(page(null), null);
      expect(c.read(myScreenProvider), isNull);
    });

    test('popping back onto the tab shell restores the tab', () {
      // Otherwise presence stays blank for the rest of the session — the tab
      // shell has no name of its own, so nothing would republish it.
      final (obs, c) = build();
      obs.didPush(page('/app'), null);
      obs.didPush(page(null), null);
      obs.didPop(page(null), page('/app'));
      expect(c.read(myScreenProvider), 'Home');
    });

    test('the shell reports whichever tab is selected', () {
      final (obs, c) = build();
      c.read(shellTabProvider.notifier).state = 1;
      obs.didPush(page('/app'), null);
      expect(c.read(myScreenProvider), 'Chat');
    });
  });
}

/// PresenceRouteObserver only ever `read`s providers, which a container does.
class _ContainerRef implements Ref {
  _ContainerRef(this._c);
  final ProviderContainer _c;

  @override
  T read<T>(ProviderListenable<T> provider) => _c.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
