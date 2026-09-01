import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/countdown_digits.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:miles/features/unlink/scene/film_library.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';
import 'package:miles/features/unlink/scene/scene_sync.dart';
import 'package:miles/features/unlink/unlink_screen.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The ritual, RENDERED.
///
/// BRAIN §193 through §199 named this check four times and never ran it: the
/// audit's one CRITICAL was that /unlink had no scrollable, so a long note or
/// a large text scale pushed Re-link — the only caller of `unlink_cancel` in
/// the whole client — off the bottom of the screen, and the ceremony became
/// uncancellable by either person. Every test written for it since has been a
/// SOURCE-law test, because mounting the screen used to drag SessionNotifier,
/// Supabase and a live socket in with it.
///
/// It no longer does. The screen watches currentProfileProvider and
/// partnerProfileProvider — the narrowest providers that answer it, per
/// providers.dart — and with no note stored, _loadNote resolves to `absent`
/// without touching the couple key.
void main() {
  // The Doorstep's slam latch lives in SharedPreferences; without a mock the
  // plugin channel would throw inside the scene's initState. The realtime
  // ear is switched off the same way TiltParallax's sensor is: there is no
  // Supabase behind a widget test, and a faked socket would test the fake.
  // Decoded ONCE, before any test — the stage kicks this same load from
  // initState, and a decode that completes mid-file lands its `.then` in a
  // test zone that has already closed.
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
    // A slam beat fires a cue; the audio plugin behind it does not exist in
    // a test, and its DISPOSAL then throws into the NEXT test's zone. The
    // stage's parallax has no accelerometer behind it either.
    MilesSound.enabled = false;
    TiltParallax.debugDefaultSource = const Stream.empty();
  });

  const meId = 'aaaaaaaa-0000-0000-0000-000000000001';
  const themId = 'bbbbbbbb-0000-0000-0000-000000000002';

  // Real profiles ALWAYS have a gender — the role-setup router gate does not
  // let anyone past without one. A genderless harness profile is how the §228
  // bug shipped (every character rendered as the fallback), and now it is how
  // the stage would render no still and no diegetic objects at all.
  Profile p(String id, String name) => Profile(
        id: id,
        displayName: name,
        timezone: 'UTC',
        gender: id == meId ? 'male' : 'female',
        genderSet: true,
        presenceStatus: PresenceStatus.free,
        createdAt: DateTime.utc(2026),
      );

  /// A ceremony anchored to now, so the gates open and close as intended
  /// rather than as the calendar happens to fall.
  Map<String, dynamic> ceremony({
    required String initiator,
    Duration relinkIn = const Duration(minutes: 15),
    Duration gateIn = const Duration(minutes: 15),
    String state = 'cooling',
    Duration? lastLookIn,
  }) {
    final now = DateTime.now().toUtc();
    return {
      'couple_id': 'cccccccc-0000-0000-0000-000000000003',
      'initiated_by': initiator,
      'state': state,
      'started_at': now.toIso8601String(),
      'cooling_ends_at':
          now.add(const Duration(hours: 24)).toIso8601String(),
      'last_look_ends_at':
          lastLookIn == null ? null : now.add(lastLookIn).toIso8601String(),
      'accepted_at': null,
      'relink_opens_at': now.add(relinkIn).toIso8601String(),
      'partner_gate_opens_at': now.add(gateIn).toIso8601String(),
      'note_cipher': null,
      'note_nonce': null,
      'note_author': null,
      'note_updated_at': null,
    };
  }

  Future<void> pump(
    WidgetTester tester, {
    required Map<String, dynamic> row,
    double textScale = 1.0,
    bool calm = false,
    Size size = const Size(360, 800),
  }) async {
    UnlinkState.applyRow(row);
    await tester.binding.setSurfaceSize(size);
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
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(calm ? 1.6 : textScale),
            ),
            child: const UnlinkScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  tearDown(() async {
    UnlinkState.reset();
    ServerClock.reset();
  });

  group('the initiator, before the gate opens', () {
    testWidgets('the STAGE shows no control at all — absence is the "not yet"',
        (tester) async {
      // The design law: no headline (the film says it), no ticking countdown
      // (a counter manufactures urgency this ritual exists to remove), no
      // dead button. The quiet absolute chip is the only chrome.
      await pump(tester, row: ceremony(initiator: meId));
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(CountdownDigits), findsNothing);
      expect(find.textContaining('Ends '), findsOneWidget,
          reason: 'when it ends is stated absolutely, without ticking',);
      expect(find.text('You stepped outside.'), findsNothing,
          reason: 'the film already says it; a headline would say it twice',);
    });

    testWidgets('the CALM layout says the words and shows the wait',
        (tester) async {
      // Animations off / big text: no film to speak, so the words return —
      // and with them the visible wait with its end.
      await pump(tester, row: ceremony(initiator: meId), calm: true);
      expect(find.text('You stepped outside.'), findsOneWidget);
      expect(find.text('The way back opens in'), findsOneWidget);
      expect(find.byType(CountdownDigits), findsOneWidget,
          reason: 'the wait must show its end, not just assert one',);
      expect(find.widgetWithText(FilledButton, 'Open the door'), findsNothing);
    });
  });

  group('the initiator, once the gate is open', () {
    testWidgets('gets Open the door, and it is enabled', (tester) async {
      await pump(
        tester,
        row: ceremony(
          initiator: meId,
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
      );
      expect(find.byType(FilledButton), findsNothing,
          reason: 'no pill returns — the key is the control',);
      final key = find.bySemanticsLabel('Open the door');
      expect(key, findsOneWidget);
      final gd = tester.widget<GestureDetector>(
        find.descendant(of: key, matching: find.byType(GestureDetector)),
      );
      expect(gd.onTap, isNotNull,
          reason: 'the only cancel control in the client must be live',);
    });

    testWidgets('the way back is REACHABLE at 2.0 text scale on a 360x800 phone',
        (tester) async {
      // THE CHECK. A 2.0 accessibility scale used to trigger the overflow with
      // no note at all — everything below the quote was laid out past the
      // bottom edge, where no pointer event can reach it.
      await pump(
        tester,
        row: ceremony(
          initiator: meId,
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
        textScale: 2,
      );
      final finder = find.widgetWithText(FilledButton, 'Open the door');
      expect(finder, findsOneWidget);
      final box = tester.getRect(finder);
      expect(box.bottom, lessThanOrEqualTo(800),
          reason: 'the way back is below the bottom edge — the ceremony is '
              'uncancellable by anyone, which is the audit CRITICAL',);
      expect(box.top, greaterThanOrEqualTo(0));
      // Hit-testable, not merely laid out inside the rectangle.
      await tester.tap(finder);
      await tester.pump();
    });
  });

  group('the partner', () {
    testWidgets('is never told what the other one did', (tester) async {
      // On the stage the scene itself is the telling — cat, sofa, worry —
      // and the words return only in the calm layout, softened to WHERE
      // their person is, never what they did.
      await pump(tester, row: ceremony(initiator: themId), calm: true);
      expect(find.text('Ayesha stepped out to the porch.'), findsOneWidget);
      // Softness is the whole point of this side of the screen. If any of
      // these words reach it, the ritual has become a verdict.
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ')
          .toLowerCase();
      for (final banned in ['unlink', 'remove', 'end the connection']) {
        expect(text.contains(banned), isFalse,
            reason: "the partner's screen said '$banned'",);
      }
    });

    testWidgets('is told the stakes anyway, with a real clock time',
        (tester) async {
      // Soft in tone, honest in substance. Being unlinked with no warning is
      // worse than being told gently.
      await pump(tester, row: ceremony(initiator: themId), calm: true);
      expect(
        find.textContaining('close your shared space'),
        findsOneWidget,
        reason: 'the one thing this screen must not leave out',
      );
    });

    testWidgets('the STAGE carries the stakes too, compressed but present',
        (tester) async {
      // The full sentence belongs to the calm layout; the stage may compress
      // it but never drop it — being unlinked with no warning is the app
      // lying by omission at its highest-stakes moment.
      await pump(tester, row: ceremony(initiator: themId));
      expect(find.textContaining('Ends '), findsOneWidget);
      expect(find.textContaining('kept safe for 30 days'), findsOneWidget);
    });

    testWidgets('is offered no chat door — the note is the channel',
        (tester) async {
      // It was there, and it was theatre: the initiator was locked out of
      // chat, so this button opened a room nobody could answer in.
      await pump(tester, row: ceremony(initiator: themId));
      expect(find.text('Talk to them'), findsNothing);
      expect(find.textContaining('Write'), findsOneWidget,
          reason: 'the note is the one channel that actually arrives',);
    });

    testWidgets('cannot agree before their own gate opens', (tester) async {
      // On the stage, absence is the answer: no danger button until the gate,
      // no ticking counter — the cat is pacing the wait. The calm layout
      // keeps the visible clock for the phone that has no cat.
      await pump(tester, row: ceremony(initiator: themId));
      expect(find.text('I need space too'), findsNothing);
      expect(find.byType(CountdownDigits), findsNothing);

      await pump(tester, row: ceremony(initiator: themId), calm: true);
      expect(find.text('I need space too'), findsNothing);
      expect(find.text('You can decide in'), findsOneWidget);
      expect(find.byType(CountdownDigits), findsOneWidget,
          reason: 'the calm layout must show when their option opens',);
    });

    testWidgets('can agree once it does, quietly', (tester) async {
      await pump(
        tester,
        row: ceremony(
          initiator: themId,
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
      );
      final photo = find.bySemanticsLabel('I need space too');
      expect(photo, findsOneWidget,
          reason: 'the photo arms only once the gate opens',);
      await tester.tap(photo);
      await tester.pump();
      expect(find.text('End it from your side too?'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'I need space too'),
          findsOneWidget,
          reason: 'agreeing to end it must never be a FilledButton',);
      await tester.tap(find.widgetWithText(TextButton, 'Not now'));
      await tester.pump();
      expect(find.text('End it from your side too?'), findsNothing);
    });
  });

  group('the exits are open at every stage, to both of them', () {
    for (final initiator in [meId, themId]) {
      final role = initiator == meId ? 'initiator' : 'partner';
      testWidgets('$role can still export and reach their account',
          (tester) async {
        await pump(tester, row: ceremony(initiator: initiator));
        expect(find.text('Save our memories'), findsOneWidget);
        expect(find.text('Account'), findsOneWidget);
      });
    }
  });

  group('last call', () {
    testWidgets('keeps the key armed for the initiator, with the reason',
        (tester) async {
      // The owner's symbol carried into the urgent moment: the key stays by
      // the door — no pill returns — and the reason stands beside it,
      // because a key with five minutes on the clock and no explanation
      // reads as a trap.
      await pump(
        tester,
        row: ceremony(
          initiator: meId,
          state: 'last_look',
          lastLookIn: const Duration(minutes: 5),
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
      );
      expect(find.byType(FilledButton), findsNothing);
      expect(find.bySemanticsLabel('Open the door'), findsOneWidget);
      expect(find.textContaining('key by the door'), findsOneWidget);
    });

    testWidgets('leaves the partner no button, because they already chose',
        (tester) async {
      await pump(
        tester,
        row: ceremony(
          initiator: themId,
          state: 'last_look',
          lastLookIn: const Duration(minutes: 5),
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
      );
      expect(find.text('I need space too'), findsNothing);
      expect(find.textContaining('You both chose this'), findsOneWidget);
    });
  });


  group('the screen stays calm', () {
    // The owner's words: "no arrangements, no alignments, too overcrowded".
    // Both people are already upset when they read it, so density is not a
    // style preference here — it is the difference between a screen that
    // holds somebody and one that adds to what they are feeling.

    testWidgets('never shows two ticking clocks at once', (tester) async {
      // The crowding had one big cause: a loud gilt "23 h 44 m left" under the
      // headline AND a live gate countdown lower down, both moving, competing
      // for the same attention. The long deadline is a quiet sentence now;
      // only the clock you can act on ticks.
      for (final row in [
        ceremony(initiator: meId),
        ceremony(
          initiator: meId,
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
        ceremony(initiator: themId),
        ceremony(
          initiator: themId,
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
        ceremony(
          initiator: meId,
          state: 'last_look',
          lastLookIn: const Duration(minutes: 5),
          relinkIn: const Duration(minutes: -1),
          gateIn: const Duration(minutes: -1),
        ),
      ]) {
        await pump(tester, row: row);
        expect(tester.widgetList(find.byType(CountdownDigits)).length,
            lessThanOrEqualTo(1),
            reason: 'two moving numbers on a screen somebody reads while '
                'upset is the crowding this design removed',);
      }
    });

    testWidgets('every line of prose is held to one measure', (tester) async {
      // Sentences ran the full 312dp of a 360dp phone, so the eye had no
      // column to follow and the screen read as a block. 300 is the cap.
      await pump(tester, row: ceremony(initiator: themId));
      for (final e in tester.widgetList<Text>(find.byType(Text))) {
        final text = e.data ?? '';
        if (text.length < 40) continue;
        final w = tester.getSize(find.text(text).first).width;
        expect(w, lessThanOrEqualTo(300.5),
            reason: 'a ${text.length}-character line is $w wide',);
      }
    });

    for (final role in ['initiator', 'partner']) {
      testWidgets('$role: nothing overflows at 2.0 text scale',
          (tester) async {
        // A RenderFlex overflow fails this test on its own. In a RELEASE
        // build it paints nothing and logs nothing — which is exactly how the
        // Begin button on the sheet before this screen ended up off the edge
        // and unreachable, with "nothing happens" as the only symptom.
        await pump(
          tester,
          row: ceremony(initiator: role == 'initiator' ? meId : themId),
          textScale: 2,
        );
      });
    }
  });

  testWidgets('a stale deep link with no ceremony shows nothing, not a crash',
      (tester) async {
    UnlinkState.reset();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentProfileProvider.overrideWithValue(p(meId, 'Me')),
          partnerProfileProvider.overrideWithValue(p(themId, 'Ayesha')),
        ],
        child: MaterialApp(
          theme: milesDarkTheme(),
          home: const UnlinkScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Nothing here anymore.'), findsOneWidget);
  });
}
