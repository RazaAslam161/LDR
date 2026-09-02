import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/features/unlink/scene/doorstep_scene.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

/// The intro film's three laws, pinned. All of them are about never trapping
/// anyone — the law the app's first intro video died for.
void main() {
  // The scene now starts an ambient bed. Off the bench there is no audio
  // engine, and a real one would leave its fade timer running past the
  // teardown this file exists to police.
  setUp(() {
    MilesSound.enabled = false;
  });
  tearDown(MilesSound.debugReset);

  UnlinkRow row() {
    final start = DateTime.utc(2026, 9, 1, 12);
    return UnlinkRow(
      coupleId: 'c1',
      initiatedBy: 'me',
      state: 'cooling',
      startedAt: start,
      coolingEndsAt: start.add(const Duration(hours: 24)),
      relinkOpensAt: start.add(const Duration(minutes: 15)),
      partnerGateOpensAt: start.add(const Duration(minutes: 15)),
      lastLookEndsAt: null,
      acceptedAt: null,
      noteCipherBytea: null,
      noteNonceBytea: null,
      noteAuthor: null,
      noteUpdatedAt: null,
    );
  }

  String latchKey(UnlinkRow r) =>
      'doorstep_intro_${r.startedAt.millisecondsSinceEpoch}_outside';

  Widget host(UnlinkRow r, {bool animationsOff = false}) => MediaQuery(
        data: MediaQueryData(disableAnimations: animationsOff),
        child: MaterialApp(
          home: SizedBox(
            width: 360,
            height: 700,
            child: DoorstepScene(
              row: r,
              role: SceneRole.outside,
              variant: PuppetVariant.male,
            ),
          ),
        ),
      );

  testWidgets('a failed film still latches, and the stage stands',
      (tester) async {
    // No video plugin exists in a widget test, which is exactly the on-device
    // case of a corrupt asset: initialize() throws. The scene must swallow
    // it, keep the stage, and — the load-bearing part — the latch must have
    // been set BEFORE the attempt, so a crash mid-film can never earn the
    // user a rewatch.
    SharedPreferences.setMockInitialValues({});
    // The failure is the subject here, so its log line is asserted rather
    // than left as noise in the run.
    final saved = debugPrint;
    final seen = <String?>[];
    debugPrint = (m, {wrapWidth}) => seen.add(m);
    final r = row();
    await tester.pumpWidget(host(r));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // Restored HERE, not in a tearDown: the framework asserts every
    // foundation debug variable is back before tearDowns run.
    debugPrint = saved;
    expect(seen, contains(startsWith('doorstep: intro failed to play')));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(latchKey(r)), isTrue,
        reason: 'latch-BEFORE-play: the film is spent the moment it is '
            'attempted, whatever happens next',);
    expect(find.byType(VideoPlayer), findsNothing,
        reason: 'the failed film must leave no player behind',);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a latched ceremony never plays again', (tester) async {
    final r = row();
    SharedPreferences.setMockInitialValues({latchKey(r): true});
    await tester.pumpWidget(host(r));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(VideoPlayer), findsNothing);
    expect(find.text('Skip'), findsNothing,
        reason: 'no film, no skip — the affordance dies with the film',);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduce-motion never plays AND never spends the film',
      (tester) async {
    // Different from failure: the film was never attempted, so if this user
    // later turns animations back on, their one showing is still theirs.
    SharedPreferences.setMockInitialValues({});
    final r = row();
    await tester.pumpWidget(host(r, animationsOff: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(latchKey(r)), isNull,
        reason: 'reduce-motion must not spend a film it never showed',);
    expect(find.byType(VideoPlayer), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
