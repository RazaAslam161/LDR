import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:miles/features/unlink/scene/film_library.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';
import 'package:miles/features/unlink/scene/scene_sync.dart';
import 'package:miles/features/unlink/unlink_repository.dart';
import 'package:miles/features/unlink/unlink_screen.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// THE CEREMONY, DRIVEN THROUGH TIME.
///
/// Every previous fix to this screen was checked with a still preview at one
/// instant, and every one of them was reported broken off the handset the same
/// day: "there is no timer", three times. A picture of one moment cannot show
/// whether anything MOVES, which is the only thing that was ever wrong.
///
/// `ServerClock` reads `DateTime.now() + offset`, and `observe()` sets that
/// offset — so a test can put the app fifteen minutes into its own future and
/// pump. That is what this file does: it walks the real screen across the real
/// window and asserts what a person would actually see.
void main() {
  setUpAll(() async {
    await SceneArt.ensureLoaded();
    for (final p in [
      FilmLibrary.stageOutM,
      FilmLibrary.stageOutF,
      FilmLibrary.stageInM,
      FilmLibrary.stageInF,
    ]) {
      await FilmLibrary.ensureStill(p);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UnlinkSceneSync.debugDisabled = true;
    MilesSound.enabled = false;
    TiltParallax.debugDefaultSource = const Stream.empty();
    // No Supabase behind a widget test: the phone-message poll answers empty
    // instead of throwing on every mount and every fifteen-second tick.
    UnlinkRepository.fetchMessages =
        (_) async => const UnlinkMessages(items: [], failedToOpen: 0);
    addTearDown(
      () => UnlinkRepository.fetchMessages = UnlinkRepository.fetchMessagesLive,
    );
  });

  tearDown(() async {
    UnlinkState.reset();
    ServerClock.reset();
  });

  const meId = 'aaaaaaaa-0000-0000-0000-000000000001';
  const themId = 'bbbbbbbb-0000-0000-0000-000000000002';

  Profile p(String id, String name) => Profile(
        id: id,
        displayName: name,
        timezone: 'UTC',
        gender: id == meId ? 'male' : 'female',
        genderSet: true,
        presenceStatus: PresenceStatus.free,
        createdAt: DateTime.utc(2026),
      );

  Map<String, dynamic> ceremony({required String initiator}) {
    final now = DateTime.now().toUtc();
    return {
      'couple_id': 'cccccccc-0000-0000-0000-000000000003',
      'initiated_by': initiator,
      'state': 'cooling',
      'started_at': now.toIso8601String(),
      'cooling_ends_at': now.add(const Duration(hours: 24)).toIso8601String(),
      'last_look_ends_at': null,
      'accepted_at': null,
      'relink_opens_at': now.add(const Duration(minutes: 15)).toIso8601String(),
      'partner_gate_opens_at':
          now.add(const Duration(minutes: 15)).toIso8601String(),
      'note_cipher': null,
      'note_nonce': null,
      'note_author': null,
      'note_updated_at': null,
    };
  }

  Future<void> pump(WidgetTester tester, {required String initiator}) async {
    UnlinkState.applyRow(ceremony(initiator: initiator));
    latchIntro();
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentProfileProvider.overrideWithValue(p(meId, 'Me')),
          partnerProfileProvider.overrideWithValue(p(themId, 'Ayesha')),
        ],
        child: MaterialApp(
          theme: milesDarkTheme(),
          home: const MediaQuery(
            data: MediaQueryData(size: Size(360, 800)),
            child: UnlinkScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Put the app [d] into its own future, then let its one-second tick land.
  Future<void> travel(WidgetTester tester, Duration d) async {
    final now = DateTime.now().toUtc();
    ServerClock.observe(now.add(d), sentAt: now);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// The one mm:ss on screen, in seconds. Null when there is no countdown.
  int? countdown(WidgetTester tester) {
    final found = find.byWidgetPredicate(
      (w) => w is Text && RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data ?? ''),
    );
    final n = found.evaluate().length;
    if (n == 0) return null;
    expect(n, 1, reason: 'exactly one countdown, or the stage has two clocks');
    final t = (found.evaluate().single.widget as Text).data!.split(':');
    return int.parse(t[0]) * 60 + int.parse(t[1]);
  }

  group('the fifteen minutes are visible and they move', () {
    testWidgets('the initiator sees a countdown that actually counts down',
        (tester) async {
      await pump(tester, initiator: meId);

      final atStart = countdown(tester);
      expect(atStart, isNotNull,
          reason: 'reported three times: "there is no timer of 15 minutes". '
              'A dial with no digits is not a timer.',);
      expect(atStart, greaterThan(14 * 60),
          reason: 'the window is fifteen minutes, not the 24-hour day — '
              'counting the day is what made the hand look frozen',);
      expect(find.text('till the door opens'), findsOneWidget,
          reason: 'a number with no sentence does not tell anyone that a '
              're-link is coming — the second thing reported',);

      await travel(tester, const Duration(minutes: 5));
      final atFive = countdown(tester);
      expect(atFive, isNotNull);
      expect(atFive, lessThan(atStart! - 4 * 60),
          reason: 'five minutes must remove about five minutes',);

      await travel(tester, const Duration(minutes: 12));
      expect(countdown(tester), lessThan(3 * 60 + 5));
    });

    testWidgets('when the gate opens the figures give way to the invitation',
        (tester) async {
      await pump(tester, initiator: meId);
      await travel(tester, const Duration(minutes: 16));

      expect(countdown(tester), isNull,
          reason: 'a number that keeps running past the thing it counted is '
              'nagging; the law that survives is that it stops',);
      expect(find.text('The key is on the door.'), findsOneWidget,
          reason: 'the moment the choice exists, the screen must say so',);
    });

    testWidgets('the partner is told they can answer, and when', (tester) async {
      await pump(tester, initiator: themId);
      expect(countdown(tester), isNotNull);
      expect(find.text('till you can answer'), findsOneWidget,
          reason: '"how would user know ... for inside character to un-link '
              'too" — this sentence is the answer',);

      await travel(tester, const Duration(minutes: 16));
      expect(countdown(tester), isNull);
      expect(find.text('You can answer now.'), findsOneWidget);
    });
  });

  group('the ending', () {
    test('fires before anything that can be interrupted', () {
      // The reunion film did not play at all: `_released()` awaited
      // loadProfile(), and the row's deletion had already made the router
      // unmount this screen, so the `if (!mounted) return` that followed threw
      // the ending away. A widget test cannot reach that path (it needs a live
      // Supabase), so the law is read off the source, the way this repo pins
      // its other structural rules.
      final src = File(
        'lib/features/unlink/unlink_screen.dart',
      ).readAsStringSync();
      final start = src.indexOf('Future<void> _released() async {');
      expect(start, greaterThan(-1), reason: '_released moved');
      final end = src.indexOf('\n  }', start);
      // Comments stripped first, the way motion_hygiene_test strips them:
      // the comment EXPLAINING this bug quotes the very string the law
      // bans, and prose about a defect must never read as the defect.
      final body =
          src.substring(start, end).replaceAll(RegExp('//.*'), '');

      final fires = body.indexOf('UnlinkEndOverlay.play.value');
      expect(fires, greaterThan(-1), reason: 'the ending is never fired');

      final bail = body.indexOf('if (!mounted) return;');
      expect(bail == -1 || bail > fires, isTrue,
          reason: 'a mounted-guard before the ending throws the film away on '
              'exactly the path that needs it — the relink, where the row is '
              'deleted and this screen is torn down mid-await',);

      expect(body.contains('ProviderScope.containerOf'), isTrue,
          reason: 'reads after the await must go through the container, which '
              'outlives this widget, not through ref',);
    });
  });
}

/// Marks the Doorstep's intro film as already seen for the ceremony
/// [UnlinkState] currently holds, both roles. The film needs a video plugin
/// that does not exist in a widget test — its init() threw "not implemented"
/// on every mount — and a spent latch is a state the scene handles by design
/// (doorstep_scene.dart: the latch is set BEFORE playback).
void latchIntro() {
  final at = UnlinkState.current.value!.startedAt.millisecondsSinceEpoch;
  SharedPreferences.setMockInitialValues({
    for (final role in const ['outside', 'inside'])
      'doorstep_intro_${at}_$role': true,
  });
}
