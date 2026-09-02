import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/unlink/scene/unlink_end_overlay.dart';

/// The overlay lives in main.dart's root Stack as a `Positioned.fill`, one
/// slot below WarmthOverlay. Build 68 shipped with SIX `_TypeError`s a launch
/// out of `Positioned.applyParentData` — the failure that greys the whole app
/// and swallows every touch, and which this file exists to make impossible to
/// ship again.
void main() {
  testWidgets('survives as a Positioned.fill directly inside a Stack',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: [
            SizedBox.expand(),
            Positioned.fill(child: UnlinkEndOverlay()),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('plays an ending without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: [
            SizedBox.expand(),
            Positioned.fill(child: UnlinkEndOverlay()),
          ],
        ),
      ),
    );
    UnlinkEndOverlay.play.value = UnlinkEnding.relink;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  group('the film outlives the light', () {
    // "Reunion video doesn't play — it appears only for a second and gone."
    // The light's envelope is 900ms; the film is ten seconds. When the light
    // completed, the ending was nulled and the whole surface collapsed with
    // the film still on it. And on a cold handset initialize() can outlast
    // the light, so the surface could fold before the film's first frame —
    // the earlier "never plays". The rule is one predicate, so the whole
    // table is a unit test rather than a handset.
    test('a playing film keeps the surface after the light has finished', () {
      expect(
        UnlinkEndOverlay.surfaceLives(
          hasKind: true,
          lightRunning: false,
          hasFilm: true,
          filmPending: false,
        ),
        isTrue,
        reason: 'the reported case: light done at 900ms, film mid-play',
      );
    });

    test('a film still initialising keeps the surface too', () {
      expect(
        UnlinkEndOverlay.surfaceLives(
          hasKind: true,
          lightRunning: false,
          hasFilm: false,
          filmPending: true,
        ),
        isTrue,
        reason: 'initialize() outlasting the light must not fold the surface '
            'before the first frame',
      );
    });

    test('with nothing owed, the surface folds', () {
      expect(
        UnlinkEndOverlay.surfaceLives(
          hasKind: true,
          lightRunning: false,
          hasFilm: false,
          filmPending: false,
        ),
        isFalse,
        reason: 'an ending must never trap the app under an empty surface',
      );
      expect(
        UnlinkEndOverlay.surfaceLives(
          hasKind: false,
          lightRunning: true,
          hasFilm: true,
          filmPending: true,
        ),
        isFalse,
        reason: 'no ending, no surface — whatever else is set',
      );
    });

    testWidgets('a failed film folds the surface once the light is done',
        (tester) async {
      // There is no video plugin on the bench, so initialize() throws — the
      // exact on-device case of a missing or corrupt asset. The light plays,
      // the film gives up, and by two seconds nothing may remain: a surface
      // that never folds is the one thing worse than a film that never plays.
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(
            children: [
              SizedBox.expand(),
              Positioned.fill(child: UnlinkEndOverlay()),
            ],
          ),
        ),
      );
      UnlinkEndOverlay.initiatorMale.value = true;
      UnlinkEndOverlay.play.value = UnlinkEnding.relink;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(DecoratedBox), findsWidgets,
          reason: 'the light is up at 300ms',);
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.descendant(
          of: find.byType(UnlinkEndOverlay),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
        reason: 'light done, film failed: the surface must have folded',
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('survives the REAL root chain: TickerMode > EmberBackground > Stack',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(
          enabled: true,
          child: EmberBackground(
            child: Stack(
              children: [
                SizedBox.expand(),
                Positioned.fill(child: UnlinkEndOverlay()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
